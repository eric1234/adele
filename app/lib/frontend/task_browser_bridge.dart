import 'dart:async';

import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/widgets.dart';

import 'prepared_frontend.dart';
import 'structured_bridge_data.dart';

/// Application-owned projection and mutations for one presented Project.
/// Execution status is read-only retained-owner evidence, not execution access.
abstract interface class TaskBrowserSource {
  Map<String, Object?> read();
  Future<void> selectTask(String? taskId);
  Future<void> createTask(String title);
  Future<void> createSession(String optionHandle);
  Future<void> openSession(String sessionId);
  void addListener(VoidCallback listener);
  void removeListener(VoidCallback listener);
  void dispose();
}

const _bridgeLibrary = 'package:adele_ui/task_browser_bridge.dart';

class TaskBrowserDeclarations implements EvalPlugin {
  const TaskBrowserDeclarations();

  @override
  String get identifier => _bridgeLibrary;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    const string = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string));
    const result = BridgeTypeAnnotation(
      BridgeTypeRef(CoreTypes.future, [
        BridgeTypeAnnotation(
          BridgeTypeRef(CoreTypes.list, [
            BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.dynamic)),
          ]),
        ),
      ]),
    );
    const listener = BridgeParameter(
      'listener',
      BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.function)),
      false,
    );
    for (final (name, returns, params) in [
      (
        'isTaskBrowserActive',
        const BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool)),
        <BridgeParameter>[],
      ),
      (
        'readTaskBrowser',
        const BridgeTypeAnnotation(
          BridgeTypeRef(CoreTypes.map, [
            string,
            BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.dynamic)),
          ]),
        ),
        <BridgeParameter>[],
      ),
      (
        'selectTask',
        result,
        const [
          BridgeParameter(
            'taskId',
            BridgeTypeAnnotation(
              BridgeTypeRef(CoreTypes.string),
              nullable: true,
            ),
            false,
          ),
        ],
      ),
      ('createTask', result, const [BridgeParameter('title', string, false)]),
      (
        'createSession',
        result,
        const [BridgeParameter('optionHandle', string, false)],
      ),
      (
        'openSession',
        result,
        const [BridgeParameter('sessionId', string, false)],
      ),
      (
        'subscribeTaskBrowser',
        const BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.voidType)),
        [listener],
      ),
      (
        'unsubscribeTaskBrowser',
        const BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.voidType)),
        [listener],
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
  void configureForRuntime(Runtime runtime) =>
      throw UnsupportedError('Use a presentation-scoped TaskBrowserBridge.');
}

final class TaskBrowserBridge extends TaskBrowserDeclarations
    implements
        PreparedFrontendBridge,
        PreparedFrontendFailureSource,
        PreparedFrontendRetainable {
  TaskBrowserBridge({
    required TaskBrowserSource source,
    required bool Function() isActive,
    VoidCallback? onDispose,
  }) : _source = source,
       _isActive = isActive,
       _onDispose = onDispose;

  final TaskBrowserSource _source;
  final bool Function() _isActive;
  final VoidCallback? _onDispose;
  final Zone _nativeZone = Zone.current;
  final Map<EvalCallable, VoidCallback> _listeners = Map.identity();
  bool _active = true;
  bool _scheduled = false;
  int _notificationGeneration = 0;
  VoidCallback? _onFailure;
  $Value? _retained;

  @override
  set onFailure(VoidCallback? callback) => _onFailure = callback;

  bool get _available {
    if (!_active) return false;
    try {
      if (_isActive()) return true;
    } on Object {
      // A failed liveness check revokes this exact presentation.
    }
    invalidate();
    return false;
  }

  void _validate() {
    if (!_available) throw StateError('Task Browser is retired.');
  }

  @override
  void configureForRuntime(Runtime runtime) {
    runtime.registerBridgeFunc(
      _bridgeLibrary,
      'isTaskBrowserActive',
      (_, _, _) => $bool(_available),
    );
    runtime.registerBridgeFunc(_bridgeLibrary, 'readTaskBrowser', (_, _, _) {
      if (_retained case final snapshot?) return snapshot;
      _validate();
      return wrapStructuredBridgeData(_source.read());
    });
    for (final (name, operation) in <(String, Future<void> Function(String?))>[
      ('selectTask', _source.selectTask),
      ('createTask', (value) => _source.createTask(value!)),
      ('createSession', (value) => _source.createSession(value!)),
      ('openSession', (value) => _source.openSession(value!)),
    ]) {
      runtime.registerBridgeFunc(_bridgeLibrary, name, (_, _, args) {
        final completion = Completer<$Value>();
        // Both invocation and settlement stay outside the evaluator's error zone.
        // Never send a rejected native Future or diagnostic exception into eval.
        _nativeZone.run(() async {
          try {
            _validate();
            await operation(args.single?.$value as String?);
            if (_active || (name != 'createSession' && name != 'openSession')) {
              _validate();
            } else if (!_isActive()) {
              throw StateError('Task Browser is retired.');
            }
            // Successful Session navigation may dispose its originating view.
            // Acknowledge the completed effect, not authority for another call;
            // the captured generation must still be live even after disposal.
            completion.complete(wrapStructuredBridgeData([true, null]));
          } on Object {
            completion.complete(
              wrapStructuredBridgeData([
                false,
                'Task Browser action could not be completed.',
              ]),
            );
          }
        });
        return $Future<$Value>.wrap(completion.future);
      });
    }
    runtime
      ..registerBridgeFunc(_bridgeLibrary, 'subscribeTaskBrowser', (
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
      ..registerBridgeFunc(_bridgeLibrary, 'unsubscribeTaskBrowser', (
        _,
        _,
        args,
      ) {
        _listeners.remove(args.single! as EvalCallable);
        if (_listeners.isEmpty && _active) {
          _source.removeListener(_changed);
          _scheduled = false;
          _notificationGeneration++;
        }
        return null;
      });
  }

  void _changed() {
    if (!_available || _scheduled || _listeners.isEmpty) return;
    // Graph and background execution-status changes share one view-local frame.
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

  void _revoke() {
    if (!_active) return;
    _active = false;
    _scheduled = false;
    _notificationGeneration++;
    if (_listeners.isNotEmpty) _source.removeListener(_changed);
    _listeners.clear();
    _onDispose?.call();
  }

  @override
  void invalidate() {
    _retained = null;
    _revoke();
  }

  @override
  void retainPresentation() {
    if (!_active) return;
    try {
      _retained = wrapStructuredBridgeData(_source.read());
    } finally {
      _revoke();
    }
  }
}
