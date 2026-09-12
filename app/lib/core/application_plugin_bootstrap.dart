import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'resource_cleanup.dart';

enum ApplicationPluginState {
  unconfigured,
  starting,
  ready,
  failed,
  closing,
  closed,
}

typedef BackendPluginActivator =
    Future<PluginCapabilityActivation> Function(
      PluginBackendHost host,
      CapabilityRegistry registry,
    );

/// Owns one shared backend host and its activations, not stock plugin selection.
final class ApplicationPluginBootstrap {
  ApplicationPluginBootstrap(this.registry);

  final CapabilityRegistry registry;
  final StreamController<ApplicationPluginState> _changes =
      StreamController<ApplicationPluginState>.broadcast();
  final List<PluginCapabilityActivation> _activations = [];
  PluginBackendHost? _host;
  ApplicationPluginState _state = ApplicationPluginState.unconfigured;
  Object? _failure;
  Future<void>? _starting;
  Future<void>? _closing;
  Future<void>? _cleanup;

  ApplicationPluginState get state => _state;
  Object? get failure => _failure;
  Stream<ApplicationPluginState> get changes => _changes.stream;

  /// Consumes prepared deployment artifacts. Never compiles or discovers source.
  /// A failed start cleans up acquired resources before reporting its failure.
  Future<void> start({
    required String dartaotruntimeExecutable,
    required String hostArtifactPath,
    required List<BackendPluginActivator> activate,
  }) {
    if (_state != ApplicationPluginState.unconfigured) {
      throw StateError('Application plugins have already started or closed.');
    }
    _setState(ApplicationPluginState.starting);
    return _starting = _start(
      dartaotruntimeExecutable,
      hostArtifactPath,
      List<BackendPluginActivator>.of(activate),
    );
  }

  Future<void> _start(
    String executable,
    String artifact,
    List<BackendPluginActivator> activate,
  ) async {
    try {
      _host = await PluginBackendHost.start(
        dartaotruntimeExecutable: executable,
        hostArtifactPath: artifact,
      );
      for (final BackendPluginActivator startPlugin in activate) {
        if (_state == ApplicationPluginState.closing) return;
        final PluginCapabilityActivation activation = await startPlugin(
          _host!,
          registry,
        );
        _activations.add(activation);
        unawaited(activation.connection.terminated.then(_terminated));
        if (activation.connection.isClosed) {
          throw StateError('A backend plugin terminated during activation.');
        }
      }
      if (_state != ApplicationPluginState.closing) {
        if (_activations.any((activation) => activation.connection.isClosed)) {
          throw StateError('A backend plugin terminated during startup.');
        }
        _setState(ApplicationPluginState.ready);
      }
    } on Object catch (error) {
      _failure = error;
      try {
        await _closeResources();
      } on Object {
        // The startup failure remains primary; close retains cleanup failure.
      }
      if (_state != ApplicationPluginState.closing) {
        _setState(ApplicationPluginState.failed);
      }
      rethrow;
    }
  }

  void _terminated(Object error) {
    if (_state != ApplicationPluginState.ready) return;
    _failure = error;
    _setState(ApplicationPluginState.failed);
    // Teardown is retained and awaited by close, including any cleanup failure.
    unawaited(_closeResources().catchError((Object _) {}));
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _setState(ApplicationPluginState.closing);
    return _closing = _close();
  }

  Future<void> _close() async {
    try {
      try {
        await _starting;
      } on Object {
        // Startup already reports its failure separately from cleanup.
      }
      await _closeResources();
    } finally {
      _setState(ApplicationPluginState.closed);
      await _changes.close();
    }
  }

  Future<void> _closeResources() => _cleanup ??= closeResources([
    // Retire every capability before stopping any plugin generation.
    for (final activation in _activations.reversed) activation.retire,
    for (final activation in _activations.reversed) activation.connection.close,
    if (_host case final PluginBackendHost host) () => host.close(),
  ]);

  void _setState(ApplicationPluginState value) {
    _state = value;
    _changes.add(value);
  }
}
