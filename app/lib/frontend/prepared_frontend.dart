import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'interpreted_widget.dart';

abstract interface class PreparedFrontendBridge implements EvalPlugin {
  void invalidate();
}

/// Optional per-view failure notification, bound before runtime configuration.
/// This callback belongs to the native owner and is never exposed to eval.
abstract interface class PreparedFrontendFailureSource {
  set onFailure(VoidCallback? callback);
}

/// Opt-in host-owned factual content for unavailable prepared presentations.
/// It stays outside eval and can update without recreating a retained runtime.
final class PreparedFrontendFallback extends InheritedWidget {
  const PreparedFrontendFallback({
    super.key,
    required this.fallback,
    required super.child,
  });

  final Widget fallback;

  static Widget? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PreparedFrontendFallback>()
      ?.fallback;

  @override
  bool updateShouldNotify(PreparedFrontendFallback oldWidget) =>
      !identical(fallback, oldWidget.fallback);
}

/// One prepared artifact generation, independent of product or view identity.
final class PreparedFrontend {
  PreparedFrontend._(this._bytes, this.failure);

  final Uint8List? _bytes;
  final Object? failure;
  final Set<_PreparedPresentationState> _presentations = {};
  bool _active = true;

  /// Retains a private immutable copy. Missing artifacts remain explicitly
  /// unavailable; bytecode decoding and entrypoint failures are bounded per view.
  static Future<PreparedFrontend> load(File artifact) async {
    try {
      return PreparedFrontend._(
        (await artifact.readAsBytes()).asUnmodifiableView(),
        null,
      );
    } on Object catch (error) {
      return PreparedFrontend._(null, error);
    }
  }

  Widget createPresentation({
    required String library,
    required String entrypoint,
    required PreparedFrontendBridge Function() createBridge,
    Key? key,
  }) => _PreparedPresentation(
    key: ValueKey((this, library, entrypoint, key)),
    generation: this,
    library: library,
    entrypoint: entrypoint,
    createBridge: createBridge,
  );

  void invalidate() {
    if (!_active) return;
    _active = false;
    for (final _PreparedPresentationState presentation
        in _presentations.toList()) {
      presentation.invalidate();
    }
  }
}

class _PreparedPresentation extends StatefulWidget {
  const _PreparedPresentation({
    super.key,
    required this.generation,
    required this.library,
    required this.entrypoint,
    required this.createBridge,
  });

  final PreparedFrontend generation;
  final String library;
  final String entrypoint;
  final PreparedFrontendBridge Function() createBridge;

  @override
  State<_PreparedPresentation> createState() => _PreparedPresentationState();
}

class _PreparedPresentationState extends State<_PreparedPresentation> {
  PreparedFrontendBridge? _bridge;
  InterpretedWidget? _loaded;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    widget.generation._presentations.add(this);
    _load();
  }

  Future<void> _load() async {
    final PreparedFrontend generation = widget.generation;
    final Uint8List? bytes = generation._bytes;
    if (!generation._active || bytes == null) {
      _failed = true;
      return;
    }
    try {
      final PreparedFrontendBridge bridge = widget.createBridge();
      _bridge = bridge;
      if (bridge is PreparedFrontendFailureSource) {
        (bridge as PreparedFrontendFailureSource).onFailure = _fail;
      }
      // The pin retains eval globals and callbacks inside Runtime. Share bytes,
      // never a Runtime, across presentations (including simultaneous views).
      final FutureOr<InterpretedWidget> pending = loadInterpretedWidget(
        bytes: bytes,
        bridge: bridge,
        library: widget.library,
        entrypoint: widget.entrypoint,
        onFailure: _fail,
      );
      final InterpretedWidget loaded = pending is Future<InterpretedWidget>
          ? await pending
          : pending;
      if (!mounted || !generation._active || _failed) return;
      setState(() => _loaded = loaded);
    } on Object {
      _fail();
    }
  }

  void _fail() {
    if (!mounted || _failed) return;
    _failed = true;
    invalidate();
  }

  void _release() {
    final PreparedFrontendBridge? bridge = _bridge;
    _bridge = null;
    _loaded = null;
    if (bridge is PreparedFrontendFailureSource) {
      (bridge as PreparedFrontendFailureSource).onFailure = null;
    }
    bridge?.invalidate();
  }

  void invalidate() {
    _release();
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _release();
    widget.generation._presentations.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed || !widget.generation._active) {
      return PreparedFrontendFallback.maybeOf(context) ??
          const Text('Frontend unavailable.');
    }
    return _loaded?.widget ??
        PreparedFrontendFallback.maybeOf(context) ??
        const SizedBox.shrink();
  }
}
