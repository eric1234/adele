import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'remote_inference_context_host.dart';
import 'resource_cleanup.dart';

enum ApplicationPluginState {
  unconfigured,
  starting,
  ready,
  failed,
  closing,
  closed,
}

enum InstalledBackendState {
  pending,
  starting,
  active,
  failed,
  terminated,
  closed,
}

/// One startup attempt, retaining its exact generation rather than a provider ID.
final class InstalledBackendActivation {
  InstalledBackendActivation._(this.installation, this._validateBootstrap);

  final PreparedPluginInstallation installation;
  final void Function() _validateBootstrap;
  InstalledBackendState _state = InstalledBackendState.pending;
  Object? _failure;
  PluginBackendConnection? _connection;
  PluginBackendActivation? _activation;

  InstalledBackendState get state => _state;
  Object? get failure => _failure;
  PluginBackendConnection? get connection => _connection;

  void validate() {
    _validateBootstrap();
    if (_state != InstalledBackendState.active || _activation == null) {
      throw StateError('The installed backend is not ready.');
    }
    _activation!.validate();
  }

  RemoteExtensionContext? strategyOrigin(
    ExtensionBinding<OrchestrationStrategyContribution> binding,
  ) {
    validate();
    return _activation!.extensionOrigin(binding);
  }

  void validateProviderOwnership(ProviderBinding binding) {
    validate();
    if (!_activation!.ownsProvider(binding)) {
      throw StateError('The provider does not belong to the owning backend.');
    }
  }

  /// Binds this presentation to the owning installation's exact ready backend.
  /// Owning affinity also captures the strategy's advertised configuration route.
  OwningBackendChannel openChannel({
    required PreparedSessionPresentation presentation,
    required ExtensionBinding<OrchestrationStrategyContribution>
    strategyBinding,
    required void Function() validatePresentation,
  }) {
    validate();
    strategyBinding.validate();
    if (strategyBinding.value.strategyId != presentation.strategyId) {
      throw ArgumentError('Presentation and strategy identities must match.');
    }
    final origin = strategyOrigin(strategyBinding);
    if (presentation.strategyAffinity ==
            PreparedStrategyAffinity.owningBackend &&
        (origin == null || !identical(origin.connection, _connection))) {
      throw StateError('The strategy does not belong to the owning backend.');
    }
    final affinityOrigin =
        presentation.strategyAffinity == PreparedStrategyAffinity.owningBackend
        ? origin
        : null;
    return OwningBackendChannel(
      connection: _connection!,
      configurationContext:
          affinityOrigin?.configurationContext ??
          _connection!.defaultConfigurationContext,
      backendServices: presentation.backendServices,
      validateOwner: () {
        validate();
        affinityOrigin?.validate();
      },
      validatePresentation: validatePresentation,
    );
  }
}

/// Discovers a prepared startup snapshot and independently attempts every backend.
/// Installation metadata is not an active capability registry.
final class ApplicationPluginBootstrap {
  ApplicationPluginBootstrap(
    this.registry,
    this.extensions, {
    this.createInfrastructureServices,
  });

  final CapabilityRegistry registry;
  final ExtensionRegistry extensions;
  final Map<String, AdeleBackendDispatcher> Function(PluginBackendConnection)?
  createInfrastructureServices;
  final RemoteExtensionAdapterRegistry _adapters =
      createRemoteExtensionAdapters();
  final StreamController<ApplicationPluginState> _changes =
      StreamController<ApplicationPluginState>.broadcast();
  final List<InstalledBackendActivation> _backends = [];
  final Map<PluginBackendConnection, Future<void>> _retiring = {};
  PreparedPluginCatalog? _catalog;
  PluginBackendHost? _host;
  ApplicationPluginState _state = ApplicationPluginState.unconfigured;
  Object? _failure;
  Future<void>? _starting;
  Future<void>? _closing;
  Future<void>? _cleanup;

  ApplicationPluginState get state => _state;
  Object? get failure => _failure;
  PreparedPluginCatalog? get catalog => _catalog;
  PluginBackendHost? get host => _host;
  List<InstalledBackendActivation> get backends => List.unmodifiable(_backends);
  Stream<ApplicationPluginState> get changes => _changes.stream;

  /// Only this catalog snapshot's exact installation can acquire its backend.
  InstalledBackendActivation? backendForInstallation(
    PreparedPluginInstallation installation,
  ) {
    if (_state != ApplicationPluginState.ready) return null;
    for (final backend in _backends) {
      if (identical(backend.installation, installation) &&
          backend.state == InstalledBackendState.active &&
          !(backend.connection?.isClosed ?? true)) {
        backend.validate();
        return backend;
      }
    }
    return null;
  }

  void _validateReady() {
    if (_state != ApplicationPluginState.ready) {
      throw StateError('Application backends are not ready.');
    }
  }

  /// Consumes prepared deployment artifacts only. An absent root is empty, not
  /// an instruction to discover source or prepare artifacts at runtime.
  Future<void> start({
    String installationRoot = const String.fromEnvironment(
      'ADELE_PLUGIN_INSTALLATION_ROOT',
    ),
    String dartaotruntimeExecutable = const String.fromEnvironment(
      'ADELE_DARTAOTRUNTIME_EXECUTABLE',
    ),
    String hostArtifactPath = const String.fromEnvironment(
      'ADELE_BACKEND_HOST_ARTIFACT',
    ),
    String startupArgumentsFile = const String.fromEnvironment(
      'ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE',
    ),
    Map<String, List<String>>? startupArguments,
  }) {
    if (_state != ApplicationPluginState.unconfigured) {
      throw StateError('Application plugins have already started or closed.');
    }
    _setState(ApplicationPluginState.starting);
    return _starting = _start(
      installationRoot,
      dartaotruntimeExecutable,
      hostArtifactPath,
      startupArgumentsFile,
      startupArguments == null
          ? null
          : {
              for (final entry in startupArguments.entries)
                entry.key: List<String>.unmodifiable(entry.value),
            },
    );
  }

  Future<void> _start(
    String root,
    String executable,
    String artifact,
    String argumentsFile,
    Map<String, List<String>>? arguments,
  ) async {
    try {
      final PreparedPluginCatalog catalog = _catalog =
          await PreparedPluginCatalog.discover(root);
      // Publish the shared snapshot before backend work. Presentation activation
      // must not wait for host startup or depend on backend readiness.
      _notify();
      _backends.addAll([
        for (final installation in catalog.installations)
          if (installation.backendArtifactUri != null)
            InstalledBackendActivation._(installation, _validateReady),
      ]);
      if (_state == ApplicationPluginState.closing) return;
      if (_backends.isEmpty) {
        _setState(ApplicationPluginState.ready);
        return;
      }
      final Map<String, List<String>> startup =
          arguments ?? await _readStartupArguments(argumentsFile);
      if (_state == ApplicationPluginState.closing) return;
      final PluginBackendHost host = _host = await PluginBackendHost.start(
        dartaotruntimeExecutable: executable,
        hostArtifactPath: artifact,
      );
      unawaited(host.terminated.then(_hostTerminated));
      for (final InstalledBackendActivation backend in _backends) {
        if (_state == ApplicationPluginState.closing) return;
        if (_failure != null) throw _failure!;
        backend._state = InstalledBackendState.starting;
        try {
          final PluginBackendConnection connection = backend._connection =
              await host.startPlugin(
                pluginId: backend.installation.metadata.id.value,
                artifactUri: backend.installation.backendArtifactUri!,
                arguments:
                    startup[backend.installation.metadata.id.value] ?? const [],
                startupArgumentsOnly: true,
                createInfrastructureServices: createInfrastructureServices,
              );
          final PluginBackendActivation activation = backend._activation =
              await PluginBackendActivation.registerAdvertised(
                connection: connection,
                capabilities: registry,
                extensions: extensions,
                adapters: _adapters,
              );
          if (connection.isClosed) {
            throw StateError('Backend terminated during activation.');
          }
          backend._state = InstalledBackendState.active;
          unawaited(
            connection.terminated.then(
              (error) => _pluginTerminated(backend, activation, error),
            ),
          );
        } on Object catch (error) {
          backend._state = InstalledBackendState.failed;
          backend._failure = error;
          if (backend.connection case final connection?) {
            final Future<void> retiring = _retiring[connection] =
                backend._activation?.close() ?? connection.close();
            try {
              await retiring;
            } on Object {
              // Preserve activation failure; close still reports cleanup failure.
            }
          }
          // A host failure during local cleanup supersedes that failure for the
          // remaining installations, not for this installation's own outcome.
          if (host.isClosed) throw await host.terminated;
        }
        _notify();
      }
      if (_failure != null) throw _failure!;
      if (_state != ApplicationPluginState.closing) {
        _setState(ApplicationPluginState.ready);
      }
    } on Object catch (error) {
      _failure ??= error;
      for (final backend in _backends) {
        if (backend._state == InstalledBackendState.pending ||
            backend._state == InstalledBackendState.starting) {
          backend._state = InstalledBackendState.failed;
          backend._failure = error;
        }
      }
      try {
        await _closeResources();
      } on Object {
        // The bootstrap failure remains primary; close retains cleanup failure.
      }
      if (_state != ApplicationPluginState.closing) {
        _setState(ApplicationPluginState.failed);
      }
      rethrow;
    }
  }

  // Temporary deployment seam, not Settings/Accounts or persisted profile state.
  // Values are opaque argv: only the owning backend interprets their contents.
  static Future<Map<String, List<String>>> _readStartupArguments(
    String path,
  ) async {
    if (path.isEmpty) return const {};
    final Object? document = jsonDecode(await File(path).readAsString());
    if (document is! Map<String, dynamic>) {
      throw const FormatException(
        'Plugin startup arguments must be an object.',
      );
    }
    return {
      for (final entry in document.entries)
        PluginId(entry.key).value: switch (entry.value) {
          final List<dynamic> values when values.every((v) => v is String) =>
            List<String>.unmodifiable(values.cast<String>()),
          _ => throw const FormatException(
            'Plugin startup arguments must be string lists.',
          ),
        },
    };
  }

  Future<void> _pluginTerminated(
    InstalledBackendActivation backend,
    PluginBackendActivation activation,
    Object error,
  ) async {
    if (_state == ApplicationPluginState.closing ||
        _state == ApplicationPluginState.closed) {
      return;
    }
    backend._state = InstalledBackendState.terminated;
    backend._failure = error;
    await activation.retire();
    _notify();
  }

  void _hostTerminated(Object error) {
    if (_state == ApplicationPluginState.closing ||
        _state == ApplicationPluginState.closed ||
        _failure != null) {
      return;
    }
    _failure = error;
    _setState(ApplicationPluginState.failed);
    // Do not snapshot resources while startup is still transferring ownership.
    unawaited(_settleAndCloseResources().catchError((Object _) {}));
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _setState(ApplicationPluginState.closing);
    return _closing = _close();
  }

  Future<void> _settleAndCloseResources() async {
    try {
      await _starting;
    } on Object {
      // Startup reports its own failure separately from cleanup.
    }
    await _closeResources();
  }

  Future<void> _close() async {
    try {
      await _settleAndCloseResources();
    } finally {
      for (final backend in _backends) {
        if (backend._state == InstalledBackendState.active ||
            backend._state == InstalledBackendState.pending) {
          backend._state = InstalledBackendState.closed;
        }
      }
      _setState(ApplicationPluginState.closed);
      await _changes.close();
    }
  }

  Future<void> _closeResources() => _cleanup ??= closeResources([
    // Retire every registration before stopping any owned generation or host.
    for (final backend in _backends.reversed)
      if (backend._activation case final activation?) activation.retire,
    for (final backend in _backends.reversed)
      if (backend.connection case final connection?)
        () =>
            _retiring[connection] ??
            backend._activation?.close() ??
            connection.close(),
    if (_host case final PluginBackendHost host) () => host.close(),
  ]);

  void _notify() {
    if (_state != ApplicationPluginState.closed) _changes.add(_state);
  }

  void _setState(ApplicationPluginState value) {
    _state = value;
    _changes.add(value);
  }
}
