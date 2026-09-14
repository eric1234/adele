import 'dart:async';
import 'dart:typed_data';

import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_eval/widgets.dart';

typedef InterpretedWidget = ({Runtime runtime, Widget widget});

/// Retains the runtime alongside its widget, preserving synchronous entrypoints.
/// An owner may also receive failures from the pin's interpreted widget lifecycle
/// through runtime-local native guards, without changing Flutter's error handlers.
FutureOr<InterpretedWidget> loadInterpretedWidget({
  required Uint8List bytes,
  required EvalPlugin bridge,
  required String library,
  required String entrypoint,
  VoidCallback? onFailure,
}) {
  final Runtime runtime = Runtime(ByteData.sublistView(bytes))
    ..addPlugin(flutterEvalPlugin)
    ..addPlugin(bridge);
  if (onFailure != null) runtime.addPlugin(_WidgetFailureGuards(onFailure));

  InterpretedWidget reify(Object? result) {
    final Object? widget = result is $Value ? result.$reified : result;
    if (widget is! Widget) {
      throw StateError('The interpreted entrypoint did not return a Widget.');
    }
    return (runtime: runtime, widget: widget);
  }

  final Object? pending = runtime.executeLib(library, entrypoint);
  return pending is Future<Object?> ? pending.then(reify) : reify(pending);
}

/// The pin registers these constructors per Runtime and permits later overrides.
/// Keep its declarations/bridge protocol; guard only native entry into interpreted
/// widgets. This deliberately does not intercept ordinary native Flutter errors.
final class _WidgetFailureGuards implements EvalPlugin {
  _WidgetFailureGuards(this._onFailure);

  final VoidCallback _onFailure;
  bool failed = false;

  void fail() {
    if (failed) return;
    failed = true;
    _onFailure();
  }

  @override
  String get identifier => 'dev.adele.prepared-frontend.widget-failures';

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {}

  @override
  void configureForRuntime(Runtime runtime) {
    const String library = 'package:flutter/src/widgets/framework.dart';
    runtime
      ..registerBridgeFunc(
        library,
        'State.',
        (_, _, _) => _GuardedState(this),
        isBridge: true,
      )
      ..registerBridgeFunc(
        library,
        'StatefulWidget.',
        (_, _, _) => _GuardedStateful(this),
        isBridge: true,
      )
      ..registerBridgeFunc(
        library,
        'StatelessWidget.',
        (_, _, _) => _GuardedStateless(this),
        isBridge: true,
      );
  }
}

class _GuardedState extends $State$bridge<StatefulWidget> {
  _GuardedState(this.failures);

  final _WidgetFailureGuards failures;
  bool _nativeDisposed = false;

  @override
  void initState() {
    if (failures.failed) return;
    try {
      super.initState();
    } on Object {
      failures.fail();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (failures.failed) return const SizedBox.shrink();
    try {
      return super.build(context);
    } on Object {
      failures.fail();
      return const SizedBox.shrink();
    }
  }

  @override
  $Value? $bridgeGet(String identifier) {
    final $Value? value = super.$bridgeGet(identifier);
    if (identifier != 'dispose') return value;
    return $Function((runtime, target, args) {
      if (_nativeDisposed) return null;
      _nativeDisposed = true;
      return (value as EvalCallable).call(runtime, target, args);
    });
  }

  @override
  void dispose() {
    try {
      // Give interpreted resource cleanup one attempt, even after a failed build.
      super.dispose();
    } on Object {
      failures.fail();
    } finally {
      // A broken/missing interpreted super.dispose must not strand native State.
      // The pin exposes that native super call through its existing bridge shim.
      if (!_nativeDisposed) {
        _nativeDisposed = true;
        (super.$bridgeGet('dispose') as EvalCallable).call(
          $runtime,
          null,
          const [],
        );
      }
    }
  }
}

class _GuardedStateful extends $StatefulWidget$bridge {
  const _GuardedStateful(this.failures);

  final _WidgetFailureGuards failures;

  @override
  State<StatefulWidget> createState() {
    if (!failures.failed) {
      try {
        return super.createState();
      } on Object {
        failures.fail();
      }
    }
    return _FailedState();
  }
}

class _FailedState extends State<StatefulWidget> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _GuardedStateless extends $StatelessWidget$bridge {
  const _GuardedStateless(this.failures);

  final _WidgetFailureGuards failures;

  @override
  Widget build(BuildContext context) {
    if (failures.failed) return const SizedBox.shrink();
    try {
      return super.build(context);
    } on Object {
      failures.fail();
      return const SizedBox.shrink();
    }
  }
}
