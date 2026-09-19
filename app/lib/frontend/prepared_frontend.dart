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

/// Revokes observation/actions while retaining read-only display during exit.
abstract interface class PreparedFrontendRetainable {
  void retainPresentation();
}

/// Presentation hosts keep their existing subtree while exit observers drain.
/// This does not retain authority or select replacement registrations.
final class PreparedFrontendRetention
    extends InheritedNotifier<ValueNotifier<bool>> {
  const PreparedFrontendRetention({
    super.key,
    required super.notifier,
    required super.child,
  });

  static bool isRetaining(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<PreparedFrontendRetention>()
          ?.notifier
          ?.value ??
      false;
}

/// Optional per-view failure notification, bound before runtime configuration.
/// This callback belongs to the native owner and is never exposed to eval.
abstract interface class PreparedFrontendFailureSource {
  set onFailure(VoidCallback? callback);
}

/// A presentation may compose independent native APIs in one eval runtime.
final class PreparedFrontendBridges
    implements
        PreparedFrontendBridge,
        PreparedFrontendFailureSource,
        PreparedFrontendRetainable {
  PreparedFrontendBridges(Iterable<PreparedFrontendBridge> bridges)
    : _bridges = List.unmodifiable(bridges);

  final List<PreparedFrontendBridge> _bridges;

  @override
  String get identifier => 'dev.adele.prepared-frontend-bridges';

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    for (final bridge in _bridges) {
      bridge.configureForCompile(registry);
    }
  }

  @override
  void configureForRuntime(Runtime runtime) {
    for (final bridge in _bridges) {
      bridge.configureForRuntime(runtime);
    }
  }

  @override
  set onFailure(VoidCallback? callback) {
    for (final bridge in _bridges) {
      if (bridge is PreparedFrontendFailureSource) {
        (bridge as PreparedFrontendFailureSource).onFailure = callback;
      }
    }
  }

  @override
  void invalidate() {
    for (final bridge in _bridges) {
      bridge.invalidate();
    }
  }

  @override
  void retainPresentation() {
    for (final bridge in _bridges) {
      if (bridge is PreparedFrontendRetainable) {
        (bridge as PreparedFrontendRetainable).retainPresentation();
      } else {
        bridge.invalidate();
      }
    }
  }
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
  final Set<PreparedFrontendBridge> _operations = {};
  bool _active = true;
  bool _retaining = false;

  /// Retains a private immutable copy. Missing artifacts remain explicitly
  /// unavailable; owners choose role-specific decode and entrypoint validation.
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

  /// Decode and resolve behavioral ABI without executing plugin code or granting
  /// native authority. Presentation-only generations retain per-view validation.
  void validateOperation({
    required String library,
    required String entrypoint,
  }) {
    _ValidationRuntime(
      ByteData.sublistView(_requireBytes()),
    ).executeLib(library, entrypoint);
  }

  /// Host-internal execution of a descriptor-selected, no-argument operation.
  /// Each call gets a fresh runtime; the role adapter must copy/validate its
  /// result before any eval-owned value can escape. Do not eagerly reify unknown
  /// values: collection reification is recursive and some eval types lose shape.
  Future<T> invoke<T>({
    required String library,
    required String entrypoint,
    required PreparedFrontendBridge Function() createBridge,
    required T Function(Object? value) decodeResult,
  }) {
    // The completion belongs to the caller's zone, not the eval error zone.
    final completion = Completer<T>();
    PreparedFrontendBridge? bridge;
    void release() {
      final owned = bridge;
      bridge = null;
      if (owned == null) return;
      _operations.remove(owned);
      owned.invalidate();
    }

    void fail(Object error, StackTrace stack) {
      if (completion.isCompleted) return;
      release();
      completion.completeError(error, stack);
    }

    late Uint8List bytes;
    late PreparedFrontendBridge operation;
    try {
      bytes = _requireBytes();
      operation = bridge = createBridge();
      _operations.add(operation);
    } on Object catch (error, stack) {
      fail(error, stack);
      return completion.future;
    }
    runZonedGuarded(() async {
      try {
        final runtime = Runtime(ByteData.sublistView(bytes))
          ..addPlugin(operation);
        final Object? result = await runtime.executeLib(library, entrypoint);
        _requireBytes();
        if (completion.isCompleted) return;
        final decoded = decodeResult(result);
        release();
        completion.complete(decoded);
      } on Object catch (error, stack) {
        fail(error, stack);
      } finally {
        release();
      }
    }, fail);
    return completion.future;
  }

  Uint8List _requireBytes() {
    if (!_active || _retaining) {
      throw StateError('The prepared frontend is retired.');
    }
    if (failure case final error?) throw error;
    return _bytes!;
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
    for (final operation in _operations) {
      operation.invalidate();
    }
    _operations.clear();
    for (final _PreparedPresentationState presentation
        in _presentations.toList()) {
      presentation.invalidate();
    }
  }

  void retainPresentations() {
    if (!_active || _retaining) return;
    _retaining = true;
    for (final operation in _operations) {
      operation.invalidate();
    }
    _operations.clear();
    for (final presentation in _presentations.toList()) {
      presentation.retainPresentation();
    }
  }

  void releasePresentations() {
    _retaining = false;
    if (_active) {
      invalidate();
    } else {
      // Registrations may have retired this generation during exit.
      for (final presentation in _presentations.toList()) {
        presentation.invalidate();
      }
    }
  }
}

/// The eval pin decodes lazily inside executeLib before dispatching execute.
/// Intercept dispatch to validate decoding/entrypoint presence without executing
/// initializers, opening a picker, or installing global runtime overrides.
final class _ValidationRuntime extends Runtime {
  _ValidationRuntime(super.bytes);

  @override
  Object? execute(int entrypoint) {
    if (entrypoint < 0 || entrypoint >= pr.length) {
      throw const FormatException('Invalid prepared operation entrypoint.');
    }
    return null;
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
    if (!generation._active || generation._retaining || bytes == null) {
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
      if (!mounted || !generation._active || generation._retaining || _failed) {
        return;
      }
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
    if (widget.generation._retaining) {
      retainPresentation();
      return;
    }
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

  void retainPresentation() {
    final bridge = _bridge;
    if (bridge is PreparedFrontendRetainable) {
      (bridge as PreparedFrontendRetainable).retainPresentation();
    } else {
      bridge?.invalidate();
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
    if (widget.generation._retaining) {
      return _loaded?.widget ?? const SizedBox.shrink();
    }
    if (_failed || !widget.generation._active) {
      return PreparedFrontendFallback.maybeOf(context) ??
          const Text('Frontend unavailable.');
    }
    return _loaded?.widget ??
        PreparedFrontendFallback.maybeOf(context) ??
        const SizedBox.shrink();
  }
}
