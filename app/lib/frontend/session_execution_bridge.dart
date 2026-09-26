import 'dart:async';

import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_eval/widgets.dart';

import 'prepared_frontend.dart';
import 'session_execution_source.dart';
import 'structured_bridge_data.dart';

export 'session_execution_source.dart' show SessionExecutionSource;

const _bridgeLibrary = 'package:adele_ui/session_execution_bridge.dart';

class SessionExecutionDeclarations implements EvalPlugin {
  const SessionExecutionDeclarations();

  @override
  String get identifier => _bridgeLibrary;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    const string = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string));
    const handle = BridgeParameter('handle', string, false);
    const listener = BridgeParameter(
      'listener',
      BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.function)),
      false,
    );
    for (final (name, returns, params) in [
      ('currentSessionId', string, <BridgeParameter>[]),
      ('readSessionExecution', structuredBridgeMapType, <BridgeParameter>[]),
      (
        'startSessionRun',
        const BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.future, [string])),
        <BridgeParameter>[],
      ),
      (
        'settleSessionOperation',
        const BridgeTypeAnnotation(
          BridgeTypeRef(CoreTypes.future, [
            BridgeTypeAnnotation(
              BridgeTypeRef(CoreTypes.list, [
                BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.dynamic)),
              ]),
            ),
          ]),
        ),
        const [
          BridgeParameter(
            'operation',
            BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.future)),
            false,
          ),
        ],
      ),
      (
        'subscribeSessionExecution',
        const BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.voidType)),
        [listener],
      ),
      (
        'unsubscribeSessionExecution',
        const BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.voidType)),
        [listener],
      ),
      ('readSessionRunActivity', structuredBridgeMapType, [handle]),
      (
        'openSessionRunActivity',
        const BridgeTypeAnnotation(
          BridgeTypeRef(CoreTypes.string),
          nullable: true,
        ),
        [const BridgeParameter('runId', string, false)],
      ),
      (
        'inspectSessionActivity',
        const BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool)),
        [handle],
      ),
      (
        'buildSessionActivity',
        const BridgeTypeAnnotation($Widget.$type),
        [handle],
      ),
    ]) {
      registry.defineBridgeTopLevelFunction(
        BridgeFunctionDeclaration(
          _bridgeLibrary,
          name,
          BridgeFunctionDef(returns: returns, params: params),
        ),
      );
    }
  }

  @override
  void configureForRuntime(Runtime runtime) => throw UnsupportedError(
    'Use a presentation-scoped SessionExecutionBridge.',
  );
}

final class SessionExecutionBridge extends SessionExecutionDeclarations
    implements
        PreparedFrontendBridge,
        PreparedFrontendFailureSource,
        PreparedFrontendRetainable {
  SessionExecutionBridge({
    required SessionExecutionSource source,
    required bool Function() isActive,
  }) : _source = source,
       _isActive = isActive;

  final SessionExecutionSource _source;
  final bool Function() _isActive;
  final Map<EvalCallable, VoidCallback> _listeners = Map.identity();
  final Set<String> _runHandles = {};
  final Set<String> _activityHandles = {};
  final Zone _nativeZone = Zone.current;
  bool _active = true;
  bool _scheduled = false;
  int _notificationGeneration = 0;
  VoidCallback? _onFailure;
  String? _retainedSessionId;
  $Value? _retainedExecution;
  final Map<String, $Value> _retainedActivity = {};
  final Map<String, Widget> _activityWidgets = {};

  @override
  set onFailure(VoidCallback? callback) => _onFailure = callback;

  bool get _available {
    if (!_active) return false;
    try {
      if (_isActive()) return true;
    } on Object {
      // Liveness failures revoke the same actions as retirement.
    }
    invalidate();
    return false;
  }

  void _validate() {
    if (!_available) throw StateError('Session execution bridge is retired.');
  }

  @override
  void configureForRuntime(Runtime runtime) {
    runtime
      ..registerBridgeFunc(_bridgeLibrary, 'currentSessionId', (_, _, _) {
        if (_retainedSessionId case final sessionId?) return $String(sessionId);
        _validate();
        return $String(_source.currentSessionId());
      })
      ..registerBridgeFunc(_bridgeLibrary, 'readSessionExecution', (_, _, _) {
        if (_retainedExecution case final execution?) return execution;
        _validate();
        return wrapStructuredBridgeData(_source.readExecution());
      })
      ..registerBridgeFunc(_bridgeLibrary, 'startSessionRun', (_, _, _) {
        final completion = Completer<$Value>();
        _nativeZone.run(() async {
          try {
            _validate();
            final handle = await _source.startRun();
            _validate();
            _runHandles.add(handle);
            completion.complete($String(handle));
          } on Object catch (error, stack) {
            completion.completeError(error, stack);
          }
        });
        completion.future.ignore();
        return $Future<$Value>.wrap(completion.future);
      })
      ..registerBridgeFunc(_bridgeLibrary, 'settleSessionOperation', (
        _,
        _,
        args,
      ) {
        final operation = args.single! as $Future;
        // Preserve interpreted instances instead of reifying or decoding them.
        // This helper grants no access; originating operations enforce liveness.
        final result = operation.$value.then<$Value>(
          (value) => $List.wrap(
            List<$Value>.unmodifiable([
              $bool(true),
              value is $Value ? value : runtime.wrap(value),
            ]),
          ),
          onError: (Object error, StackTrace stack) => $List.wrap(
            List<$Value>.unmodifiable([$bool(false), const $null()]),
          ),
        );
        return $Future<$Value>.wrap(result);
      })
      ..registerBridgeFunc(_bridgeLibrary, 'openSessionRunActivity', (
        _,
        _,
        args,
      ) {
        _validate();
        final handle = _source.openRunActivity(args.single!.$value as String);
        if (handle == null) return const $null();
        _runHandles.add(handle);
        return $String(handle);
      })
      ..registerBridgeFunc(_bridgeLibrary, 'readSessionRunActivity', (
        _,
        _,
        args,
      ) {
        if (_retainedActivity[args.single!.$value as String]
            case final activity?) {
          return activity;
        }
        _validate();
        final handle = args.single!.$value as String;
        if (!_runHandles.contains(handle)) {
          throw StateError('Run handle was not emitted to this view.');
        }
        final snapshot = _source.readRunActivity(handle);
        final boxed = wrapStructuredBridgeData(snapshot);
        // Commit action handles only after the entire snapshot is transportable.
        // Failed reads must not authorize guesses at newly allocated handles.
        final emitted = <String>[];
        for (final model in snapshot['models']! as List) {
          emitted.add((model as Map)['handle']! as String);
          for (final output in model['outputs']! as List) {
            emitted.add((output as Map)['handle']! as String);
          }
        }
        _activityHandles.addAll(emitted);
        return boxed;
      })
      ..registerBridgeFunc(
        _bridgeLibrary,
        'inspectSessionActivity',
        (_, _, args) => $bool(
          _available &&
              _activityHandles.contains(args.single!.$value as String) &&
              _source.inspectActivity(args.single!.$value as String),
        ),
      )
      ..registerBridgeFunc(_bridgeLibrary, 'buildSessionActivity', (
        _,
        _,
        args,
      ) {
        final handle = args.single!.$value as String;
        if (_retainedExecution != null) {
          return $Widget.wrap(
            _activityWidgets[handle] ?? const SizedBox.shrink(),
          );
        }
        if (!_available || !_activityHandles.contains(handle)) {
          return $Widget.wrap(const SizedBox.shrink());
        }
        final widget = _source.buildActivity(handle);
        _activityWidgets[handle] = widget;
        return $Widget.wrap(widget);
      })
      ..registerBridgeFunc(_bridgeLibrary, 'subscribeSessionExecution', (
        _,
        _,
        args,
      ) {
        if (!_available) return null;
        final listener = args.single! as EvalCallable;
        if (_listeners.containsKey(listener)) return null;
        if (_listeners.isEmpty) _source.addListener(_changed);
        _listeners[listener] = () => listener.call(runtime, null, const []);
        return null;
      })
      ..registerBridgeFunc(_bridgeLibrary, 'unsubscribeSessionExecution', (
        _,
        _,
        args,
      ) {
        _listeners.remove(args.single! as EvalCallable);
        if (_listeners.isEmpty) {
          _source.removeListener(_changed);
          _scheduled = false;
          _notificationGeneration++;
        }
        return null;
      });
  }

  void _changed() {
    if (!_available || _scheduled || _listeners.isEmpty) return;
    _scheduled = true;
    final queued = Map.of(_listeners);
    final generation = _notificationGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (generation != _notificationGeneration) return;
      _scheduled = false;
      if (!_available) return;
      for (final entry in queued.entries) {
        if (!_available) return;
        if (!identical(_listeners[entry.key], entry.value)) continue;
        try {
          entry.value();
        } on Object {
          invalidate();
          _onFailure?.call();
          return;
        }
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void invalidate() {
    _retainedSessionId = null;
    _retainedExecution = null;
    _retainedActivity.clear();
    _activityWidgets.clear();
    _active = false;
    _runHandles.clear();
    _activityHandles.clear();
    if (_listeners.isNotEmpty) _source.removeListener(_changed);
    _listeners.clear();
    _source.invalidate();
  }

  @override
  void retainPresentation() {
    if (!_active) return;
    _retainedSessionId = _source.currentSessionId();
    _retainedExecution = wrapStructuredBridgeData({
      ..._source.readExecution(),
      'canStart': false,
    });
    for (final handle in _runHandles) {
      _retainedActivity[handle] = wrapStructuredBridgeData(
        _source.readRunActivity(handle),
      );
    }
    _active = false;
    if (_listeners.isNotEmpty) _source.removeListener(_changed);
    _listeners.clear();
    if (_source is PreparedFrontendRetainable) {
      (_source as PreparedFrontendRetainable).retainPresentation();
    } else {
      _source.invalidate();
    }
  }
}
