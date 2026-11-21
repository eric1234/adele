import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_plugin_backend_support/adele_backend_configuration.dart';
import 'package:adele_plugin_backend_support/adele_backend_credentials.dart';
import 'package:adele_plugin_backend_support/adele_capability_publisher.dart';
import 'package:adele_plugin_backend_support/capability_consumer.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'backend_capability_host.dart';
import 'backend_capability_publication_host.dart';
import 'backend_configuration_host.dart';
import 'backend_credential_host.dart';
import 'prepared_records.dart';
import 'prepared_settings.dart';
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
  BackendCredentialHost? _credentials;
  BackendConfigurationHost? _configuration;
  BackendCapabilityPublicationHost? _publication;

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

  /// Observes retirement of this exact captured backend generation.
  void Function() onRetire(void Function() observer) {
    validate();
    return _activation!.onRetire(observer);
  }

  RemoteExtensionContext? strategyOrigin(
    ExtensionBinding<OrchestrationStrategyContribution> binding,
  ) => extensionOrigin(binding);

  /// Resolves ownership of an exact registration, not a matching Extension ID.
  RemoteExtensionContext? extensionOrigin(ExtensionBinding<Object> binding) {
    validate();
    return _activation!.extensionOrigin(binding);
  }

  void validateProviderOwnership(ProviderBinding binding) {
    validate();
    if (!_activation!.ownsProvider(binding)) {
      throw StateError('The provider does not belong to the owning backend.');
    }
  }

  /// Synchronously fences one exact owned provider, preserving its live siblings.
  Future<void> retireProvider(ProviderBinding binding) {
    validate();
    return _activation!.retireProvider(binding);
  }

  ProviderBinding? associationFor(ProviderBinding binding) {
    validate();
    return _activation!.associationFor(binding);
  }

  bool isEnvironmentBound(ProviderBinding binding) {
    validate();
    return _activation!.isEnvironmentBound(binding);
  }

  bool allowsEnvironmentHostService(
    ProviderBinding binding,
    AdeleEnvironmentHostService service,
  ) {
    validate();
    return _activation!.allowsEnvironmentHostService(binding, service);
  }

  ProviderBinding resolveAssociatedProvider(
    CapabilityKey capability, {
    required ProviderBinding associatedWith,
    ProviderId? providerId,
  }) {
    validate();
    return _activation!.resolveAssociatedProvider(
      capability,
      associatedWith: associatedWith,
      providerId: providerId,
    );
  }

  /// Binds this presentation to the owning installation's exact ready backend.
  /// Owning affinity also captures the strategy's advertised configuration route.
  OwningBackendChannel openChannel({
    required Iterable<String> backendServices,
    required PreparedStrategyAffinity strategyAffinity,
    ExtensionBinding<OrchestrationStrategyContribution>? strategyBinding,
    required void Function() validatePresentation,
  }) {
    validate();
    strategyBinding?.validate();
    final origin = strategyBinding == null
        ? null
        : strategyOrigin(strategyBinding);
    if (strategyAffinity == PreparedStrategyAffinity.owningBackend &&
        (origin == null || !identical(origin.connection, _connection))) {
      throw StateError('The strategy does not belong to the owning backend.');
    }
    final affinityOrigin =
        strategyAffinity == PreparedStrategyAffinity.owningBackend
        ? origin
        : null;
    return openPresentationChannel(
      backendServices: backendServices,
      configurationOrigin: affinityOrigin,
      validatePresentation: validatePresentation,
    );
  }

  /// Captures this exact installation/context without resolving a strategy or
  /// granting execution authority. Only Session affinity supplies an origin.
  OwningBackendChannel openPresentationChannel({
    required Iterable<String> backendServices,
    required void Function() validatePresentation,
    RemoteExtensionContext? configurationOrigin,
  }) {
    validate();
    if (configurationOrigin != null) {
      configurationOrigin.validate();
      if (!identical(configurationOrigin.connection, _connection)) {
        throw StateError('The configuration belongs to another backend.');
      }
    }
    return OwningBackendChannel(
      connection: _connection!,
      configurationContext:
          configurationOrigin?.configurationContext ??
          _connection!.defaultConfigurationContext,
      backendServices: backendServices,
      observeOwnerRetirement: _activation!.onRetire,
      validateOwner: () {
        validate();
        configurationOrigin?.validate();
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
    Future<PreparedSettingsSnapshot> Function(PreparedPluginCatalog)?
    loadSettings,
    Future<StartupRecordsView> Function(
      PreparedPluginCatalog,
      PreparedPluginInstallation,
    )?
    loadRecords,
    CurrentRecordsLoader? loadCurrentRecords,
    StartupCredentialReader Function()? credentialAssociations,
  }) : _loadSettings = loadSettings ?? PreparedSettingsSnapshot.load,
       _loadRecords = loadRecords,
       _loadCurrentRecords = loadCurrentRecords,
       _credentialAssociations = credentialAssociations;

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
  Map<PreparedPluginInstallation, List<ExtensionId>>?
  _expectedToolAuthorizationPolicies;
  StateError? _authorizationSettingsFailure;
  PluginBackendHost? _host;
  ApplicationPluginState _state = ApplicationPluginState.unconfigured;
  Object? _failure;
  Future<void>? _starting;
  Future<void>? _closing;
  Future<void>? _cleanup;
  bool _startsStopped = false;
  Future<PreparedSettingsSnapshot> Function(PreparedPluginCatalog)
  _loadSettings;
  Future<PreparedSettingsSnapshot>? _settings;
  Future<StartupRecordsView> Function(
    PreparedPluginCatalog,
    PreparedPluginInstallation,
  )?
  _loadRecords;
  CurrentRecordsLoader? _loadCurrentRecords;
  StartupCredentialReader Function()? _credentialAssociations;

  /// Binds the composition root's shared I/O owner before either component starts.
  void configureSettingsLoader(
    Future<PreparedSettingsSnapshot> Function(PreparedPluginCatalog) loader,
  ) {
    if (_state != ApplicationPluginState.unconfigured) {
      throw StateError('Plugin settings must be configured before startup.');
    }
    _loadSettings = loader;
  }

  /// Binds the host-owned read-only record projection before backend startup.
  /// Standalone hosts must supply this explicitly for opted-in installations.
  void configureRecordsLoader(
    Future<StartupRecordsView> Function(
      PreparedPluginCatalog,
      PreparedPluginInstallation,
    )
    loader,
  ) {
    if (_state != ApplicationPluginState.unconfigured) {
      throw StateError('Plugin records must be configured before startup.');
    }
    _loadRecords = loader;
  }

  /// Supplies independent live observations, never a startup credential capture.
  void configureCurrentRecordsLoader(CurrentRecordsLoader loader) {
    if (_state != ApplicationPluginState.unconfigured) {
      throw StateError(
        'Live backend records must be configured before startup.',
      );
    }
    _loadCurrentRecords = loader;
  }

  /// Supplies the trusted coordinator paired with the startup record worker.
  /// Neither construction nor registration reads protected storage.
  void configureCredentialAssociations(
    StartupCredentialReader Function() associations,
  ) {
    if (_state != ApplicationPluginState.unconfigured) {
      throw StateError(
        'Backend credentials must be configured before startup.',
      );
    }
    _credentialAssociations = associations;
  }

  /// Both independent component owners consume one startup resolution.
  Future<PreparedSettingsSnapshot> settingsForCatalog(
    PreparedPluginCatalog catalog,
  ) {
    if (!identical(catalog, _catalog)) {
      throw StateError('Settings belong to another prepared catalog snapshot.');
    }
    return _settings ??= Future.sync(() => _loadSettings(catalog)).catchError(
      (Object error) => PreparedSettingsSnapshot.fromFailure(catalog, error),
    );
  }

  ApplicationPluginState get state => _state;
  Object? get failure => _failure;
  PreparedPluginCatalog? get catalog => _catalog;
  PluginBackendHost? get host => _host;
  List<InstalledBackendActivation> get backends => List.unmodifiable(_backends);
  Stream<ApplicationPluginState> get changes => _changes.stream;

  /// Checks both installed expectations and known advertisements. The returned
  /// validator pins their exact live origins only through preference capture.
  void Function() captureExpectedRunModelPreferences(
    List<ExtensionBinding<RunModelPreferenceContribution>> bindings,
  ) {
    const unavailable = RunModelPreferenceFailure(
      RunModelPreferenceFailureKind.unavailable,
    );
    final catalog = _catalog;
    if (_state == ApplicationPluginState.starting ||
        _state == ApplicationPluginState.closing ||
        _state == ApplicationPluginState.closed ||
        (_state == ApplicationPluginState.failed && catalog == null) ||
        (catalog?.issues.any((i) => i.isRunModelPreferenceSourceIssue) ??
            false)) {
      throw unavailable;
    }
    final outstanding = {
      for (final installation
          in catalog?.installations ?? const <PreparedPluginInstallation>[])
        installation: ?installation.runModelPreferenceSource,
    };
    final captured = <(InstalledBackendActivation, RemoteExtensionContext)>[];
    for (final backend in _backends) {
      // The attempt retains its original connection, even if registration was
      // rolled back. Never accept a native or replacement binding by ID alone.
      final connection = backend.connection;
      if (connection == null) continue;
      for (final exposure in connection.extensionExposures) {
        if (exposure.extensionPointId !=
            runModelPreferencesExtensionPoint.value) {
          continue;
        }
        final binding = bindings
            .where((item) => item.id.value == exposure.extensionId)
            .singleOrNull;
        if (binding == null ||
            connection.isClosed ||
            backend.state != InstalledBackendState.active) {
          throw unavailable;
        }
        final origin = backend.extensionOrigin(binding);
        if (origin == null || !identical(origin.exposure, exposure)) {
          throw unavailable;
        }
        captured.add((backend, origin));
        if (outstanding[backend.installation] == binding.id) {
          outstanding.remove(backend.installation);
        }
      }
    }
    // A missing artifact, failed start, or another installation's successful
    // advertisement cannot discharge this installation's declaration.
    if (outstanding.isNotEmpty) throw unavailable;
    return () {
      for (final (backend, origin) in captured) {
        backend.validate();
        origin.validate();
      }
    };
  }

  /// Immutable startup/global participation, independent of live registrations.
  /// Contextual enablement must resolve against the canonical execution context
  /// before narrowing this snapshot; it is not implemented by startup discovery.
  Map<PreparedPluginInstallation, List<ExtensionId>>
  get expectedToolAuthorizationPolicies {
    if (_authorizationSettingsFailure case final failure?) throw failure;
    return _expectedToolAuthorizationPolicies ??
        (throw StateError('Tool authorization participation is unresolved.'));
  }

  void _resolveToolAuthorizationPolicies(
    PreparedPluginCatalog catalog,
    PreparedSettingsSnapshot? settings,
  ) {
    final expected = <PreparedPluginInstallation, List<ExtensionId>>{};
    for (final installation in catalog.installations) {
      final applicable = <ExtensionId>[];
      for (final id in installation.authorizationPolicies) {
        final key = installation.authorizationPolicyEnabledSettings[id];
        if (key != null) {
          try {
            final enabled =
                settings!.read(installation, key.value).value as bool;
            if (!enabled) continue;
          } on Object {
            // Keep starting independent installations. Never publish a partial
            // expectation set as a successful authorization resolution.
            _authorizationSettingsFailure = StateError(
              'Cannot resolve tool authorization setting $key for '
              '${installation.metadata.id} (policy $id).',
            );
            return;
          }
        }
        applicable.add(id);
      }
      if (applicable.isNotEmpty) {
        expected[installation] = List.unmodifiable(applicable);
      }
    }
    _expectedToolAuthorizationPolicies = Map.unmodifiable(expected);
  }

  /// Checks this request's registrations and retains their exact backend origins.
  /// The returned check never rediscovers or substitutes a replacement generation.
  void Function() captureExpectedToolAuthorizationPolicies(
    List<ExtensionBinding<ToolAuthorizationPolicyContribution>> bindings,
  ) {
    final catalog = _catalog;
    if (catalog == null ||
        (_state != ApplicationPluginState.ready &&
            _state != ApplicationPluginState.failed)) {
      throw StateError(
        'Expected tool authorization participation is unavailable.',
      );
    }
    for (final issue in catalog.issues) {
      if (issue.isAuthorizationPolicyIssue) {
        throw StateError(
          'Invalid tool authorization participation for '
          '${issue.pluginId ?? issue.installationDirectory.path}: '
          '${issue.message}',
        );
      }
    }
    final captured = <(InstalledBackendActivation, RemoteExtensionContext)>[];
    for (final entry in expectedToolAuthorizationPolicies.entries) {
      final installation = entry.key;
      final backend = backendForInstallation(installation);
      if (backend == null) {
        final attempts = _backends.where(
          (attempt) => identical(attempt.installation, installation),
        );
        final state = attempts.isEmpty
            ? 'no valid backend'
            : attempts.single.state.name;
        throw StateError(
          'Expected tool authorization backend ${installation.metadata.id} '
          'is unavailable ($state).',
        );
      }
      for (final id in entry.value) {
        final matches = bindings.where((binding) => binding.id == id);
        if (matches.isEmpty) {
          throw StateError(
            'Expected tool authorization policy $id is missing.',
          );
        }
        final origin = backend.extensionOrigin(matches.single);
        if (origin == null) {
          throw StateError(
            'Expected tool authorization policy $id belongs to another installation.',
          );
        }
        captured.add((backend, origin));
      }
    }
    return () {
      for (final (backend, origin) in captured) {
        backend.validate();
        origin.validate();
      }
    };
  }

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

  /// Finds the active owner of this exact registration, not its advertised IDs.
  InstalledBackendActivation? backendForProvider(ProviderBinding binding) {
    binding.endpointAs<CapabilityEndpoint>();
    if (_state != ApplicationPluginState.ready) return null;
    for (final backend in _backends) {
      if (backend.state == InstalledBackendState.active &&
          !(backend.connection?.isClosed ?? true) &&
          backend._activation!.ownsProvider(binding)) {
        backend.validate();
        return backend;
      }
    }
    return null;
  }

  /// Preserves sibling ordering; independent providers require unique selection.
  /// Eligibility is not an invocation grant or a provider-applicability claim.
  ProviderBinding resolveEnvironmentCapabilityProvider(
    CapabilityKey capability, {
    required ProviderBinding associatedWith,
    ProviderId? providerId,
  }) {
    final environmentOwner = backendForProvider(associatedWith);
    var siblingProviderIds = const <Object>[];
    final independent = <ProviderBinding>[];
    if (environmentOwner != null) {
      try {
        return environmentOwner.resolveAssociatedProvider(
          capability,
          associatedWith: associatedWith,
          providerId: providerId,
        );
      } on CapabilityUnavailable {
        // No eligible siblings. Independent declarations are a separate mode.
      } on ProviderUnavailable catch (error) {
        if (error.stale) rethrow;
        siblingProviderIds = error.availableProviderIds;
      }
      for (final provider in registry.providersFor(capability)) {
        final binding = registry.resolve(capability, providerId: provider.id);
        final owner = backendForProvider(binding);
        if (owner != null && owner.isEnvironmentBound(binding)) {
          independent.add(binding);
        }
      }
    }
    if (providerId != null) {
      for (final binding in independent) {
        if (binding.provider.id == providerId) return binding;
      }
      throw ProviderUnavailable(
        capability: capability,
        providerId: providerId,
        availableProviderIds: [
          ...siblingProviderIds,
          for (final binding in independent) binding.provider.id,
        ],
      );
    }
    if (independent.isEmpty) throw CapabilityUnavailable(capability);
    if (independent.length != 1) {
      throw StateError('Environment-bound Capability selection is ambiguous.');
    }
    return independent.single;
  }

  void _validateReady() {
    if (_state != ApplicationPluginState.ready) {
      throw StateError('Application backends are not ready.');
    }
  }

  /// Fences new backend starts without retiring generations needed by draining
  /// application work. Terminal cleanup still belongs to [close].
  void stopStarting() => _startsStopped = true;

  bool get _cannotStart =>
      _startsStopped || _state == ApplicationPluginState.closing;

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
    if (_startsStopped || _state != ApplicationPluginState.unconfigured) {
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
      if (_cannotStart) return;
      // Resolve even for installations without a usable artifact. Backend
      // readiness is not evidence for whether a declared policy is applicable.
      final conditional = catalog.installations.any(
        (installation) =>
            installation.authorizationPolicyEnabledSettings.isNotEmpty,
      );
      _resolveToolAuthorizationPolicies(
        catalog,
        conditional ? await settingsForCatalog(catalog) : null,
      );
      if (_cannotStart) return;
      if (_backends.isEmpty) {
        _setState(ApplicationPluginState.ready);
        return;
      }
      final Map<String, List<String>> startup =
          arguments ?? await _readStartupArguments(argumentsFile);
      if (_cannotStart) return;
      final PluginBackendHost host = _host = await PluginBackendHost.start(
        dartaotruntimeExecutable: executable,
        hostArtifactPath: artifact,
      );
      unawaited(host.terminated.then(_hostTerminated));
      for (final InstalledBackendActivation backend in _backends) {
        if (_cannotStart) return;
        if (_failure != null) throw _failure!;
        backend._state = InstalledBackendState.starting;
        StartupRecordsView? recordSnapshot;
        StartupCredentialReader? credentialAssociations;
        try {
          final settings = (await settingsForCatalog(
            catalog,
          )).valuesForInstallation(backend.installation);
          if (_cannotStart) return;
          final List<Map<String, Object?>> records;
          if (backend.installation.backendConsumedCredentialSlots.any(
            (declaration) => declaration.slots.isNotEmpty,
          )) {
            if (_credentialAssociations == null) {
              throw StateError('Backend credential access is not configured.');
            }
          }
          if (backend.installation.backendConsumedRecordTypes.isEmpty) {
            records = const [];
          } else {
            final loader = _loadRecords;
            if (loader == null) {
              throw StateError('Backend record loading is not configured.');
            }
            recordSnapshot = await loader(catalog, backend.installation);
            records = recordSnapshot.recordsForInstallation(
              catalog,
              backend.installation,
            );
            if (backend.installation.backendConsumedCredentialSlots.any(
              (declaration) => declaration.slots.isNotEmpty,
            )) {
              credentialAssociations = _credentialAssociations!();
            }
          }
          if (_cannotStart) return;
          final PluginBackendConnection
          connection = backend._connection = await host.startPlugin(
            pluginId: backend.installation.metadata.id.value,
            artifactUri: backend.installation.backendArtifactUri!,
            arguments:
                startup[backend.installation.metadata.id.value] ?? const [],
            startupArgumentsOnly: true,
            settings: settings,
            records: records,
            recordApplyHandlers:
                backend.installation.backendRecordApplyHandlers,
            createInfrastructureServices: (connection) {
              final services = <String, AdeleBackendDispatcher>{
                ...?createInfrastructureServices?.call(connection),
              };
              final allowed = backend.installation.backendConsumedCapabilities;
              if (services.containsKey(backendCapabilityPublicationServiceId)) {
                throw StateError(
                  'Capability publication is already configured.',
                );
              }
              // Publication continues the backend's existing advertisement
              // authority, scoped to its actual connection, not consumption.
              services[backendCapabilityPublicationServiceId] =
                  backend._publication = BackendCapabilityPublicationHost(
                    connection: connection,
                  );
              if (services.containsKey(backendCapabilityConsumerServiceId)) {
                throw StateError(
                  'Capability mediation service is already configured.',
                );
              }
              if (services.containsKey(backendCredentialServiceId)) {
                throw StateError(
                  'Credential access service is already configured.',
                );
              }
              if (services.containsKey(backendConfigurationServiceId)) {
                throw StateError(
                  'Configuration access service is already configured.',
                );
              }
              if (backend.installation.backendConsumedRecordTypes.isNotEmpty &&
                  _loadCurrentRecords != null) {
                services[backendConfigurationServiceId] =
                    backend._configuration = BackendConfigurationHost(
                      connection: connection,
                      catalog: catalog,
                      installation: backend.installation,
                      loadRecords: _loadCurrentRecords!,
                    );
              }
              if (credentialAssociations case final associations?) {
                services[backendCredentialServiceId] = backend._credentials =
                    BackendCredentialHost(
                      connection: connection,
                      catalog: catalog,
                      installation: backend.installation,
                      records: recordSnapshot!,
                      associations: associations,
                    );
              }
              if (allowed.isNotEmpty) {
                final consumer = BackendCapabilityHost(
                  connection: connection,
                  registry: registry,
                  allowedCapabilities: allowed,
                  ownerForProvider: _capabilityOwner,
                );
                services[backendCapabilityConsumerServiceId] =
                    BackendCapabilityConsumerServiceDispatcher(
                      consumer,
                      concurrent: true,
                    );
              }
              return services;
            },
          );
          for (final exposure in connection.extensionExposures) {
            if (exposure.extensionPointId != toolAuthorizationPolicies.value) {
              continue;
            }
            final key =
                backend
                    .installation
                    .authorizationPolicyEnabledSettings[ExtensionId(
                  exposure.extensionId,
                )];
            if (key != null && settings[key.value] == false) {
              throw StateError(
                '${backend.installation.metadata.id} advertised disabled '
                'tool authorization policy ${exposure.extensionId}.',
              );
            }
          }
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
          backend._publication!.attach(activation);
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
        } finally {
          if (backend._credentials == null &&
              credentialAssociations != null &&
              recordSnapshot != null) {
            await credentialAssociations.releaseStartupRecords(recordSnapshot);
          }
        }
        _notify();
      }
      if (_failure != null) throw _failure!;
      if (!_cannotStart) {
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

  PluginBackendActivation? _capabilityOwner(ProviderBinding binding) {
    if (_state != ApplicationPluginState.starting &&
        _state != ApplicationPluginState.ready) {
      return null;
    }
    for (final backend in _backends) {
      if (backend.state == InstalledBackendState.active &&
          !(backend.connection?.isClosed ?? true) &&
          backend._activation!.ownsProvider(binding)) {
        return backend._activation;
      }
    }
    return null;
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
    try {
      await activation.retire();
    } on Object {
      // Preserve termination; explicit close observes the cached retirement failure.
    }
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
    for (final backend in _backends) {
      // Revocation settles pending reverse calls now; it must not queue behind
      // the credential owner's drain of an uncancelable native unlock prompt.
      (backend.connection ??
              backend._credentials?.connection ??
              backend._configuration?.connection ??
              backend._publication?.connection)
          ?.revokeInfrastructureContext();
      unawaited(backend._credentials?.close());
      unawaited(backend._configuration?.close());
      unawaited(backend._publication?.close());
    }
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
            backend._state == InstalledBackendState.starting ||
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
      if (backend._credentials case final credentials?) credentials.close,
    for (final backend in _backends.reversed)
      if (backend._configuration case final configuration?) configuration.close,
    for (final backend in _backends.reversed)
      if (backend._publication case final publication?) publication.close,
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
