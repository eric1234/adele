import 'dart:async';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/widgets.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../core/application_plugin_bootstrap.dart';
import '../core/resource_cleanup.dart';
import 'console_bridge.dart';
import 'directory_picker_bridge.dart';
import 'model_native_activity_bridge.dart';
import 'owning_backend_bridge.dart';
import 'prepared_console_host.dart';
import 'prepared_frontend.dart';
import 'prepared_main_content_host.dart';
import 'prepared_session_services.dart';
import 'prepared_task_browser_host.dart';
import 'terminal_projection_bridge.dart';
import 'tool_activity_inspection_bridge.dart';

enum ApplicationFrontendState { unconfigured, starting, ready, closing, closed }

enum InstalledFrontendState {
  pending,
  starting,
  active,
  failed,
  closing,
  closed,
}

/// Owns one startup snapshot of prepared frontends, independently of backends.
final class ApplicationFrontendBootstrap {
  ApplicationFrontendBootstrap({
    required ExtensionRegistry extensions,
    ApplicationPluginBootstrap? backends,
    PreparedSessionServices? sessionServices,
    PreparedTaskBrowserHost? taskBrowserHost,
    PreparedConsoleHost? consoleHost,
    PreparedMainContentHost? mainContentHost,
  }) : _extensions = extensions,
       _backends = backends,
       _sessionServices = sessionServices,
       _taskBrowserHost = taskBrowserHost,
       _consoleHost = consoleHost,
       _mainContentHost = mainContentHost ?? PreparedMainContentHost();

  final ExtensionRegistry _extensions;
  final ApplicationPluginBootstrap? _backends;
  final PreparedSessionServices? _sessionServices;
  final PreparedTaskBrowserHost? _taskBrowserHost;
  final PreparedConsoleHost? _consoleHost;
  final PreparedMainContentHost _mainContentHost;
  final List<InstalledFrontendActivation> _generations = [];
  final StreamController<ApplicationFrontendState> _changes =
      StreamController<ApplicationFrontendState>.broadcast();
  ApplicationFrontendState _state = ApplicationFrontendState.unconfigured;
  PreparedPluginCatalog? _catalog;
  Future<void>? _starting;
  Future<void>? _closing;

  ApplicationFrontendState get state => _state;
  PreparedPluginCatalog? get catalog => _catalog;
  List<InstalledFrontendActivation> get generations =>
      List.unmodifiable(_generations);
  Stream<ApplicationFrontendState> get changes => _changes.stream;

  Future<void> prepareToDeactivate(Session session) =>
      _mainContentHost.prepareToDeactivate(session);

  void unbind(Session session) => _mainContentHost.unbind(session);

  Future<bool> prepareToExit() => _mainContentHost.prepareToExit();

  Future<void> stopMainContentOperations() => _mainContentHost.stopOperations();

  /// Prepared selectors require their exact installation's provider registration,
  /// not merely a matching PluginId declared by an unrelated endpoint.
  void validateProjectProvider(
    ExtensionBinding<ProjectSelectorContribution> selector,
    ProviderBinding provider,
    ApplicationPluginBootstrap backends,
  ) {
    selector.validate();
    provider.endpointAs<CapabilityEndpoint>();
    if (selector.value.projectProviderId != provider.provider.id) {
      throw StateError('The selector names another Project provider.');
    }
    for (final generation in _generations) {
      if (generation.registrations.any((entry) => entry.owns(selector))) {
        final owner = backends.backendForInstallation(generation.installation);
        if (owner == null) {
          throw StateError(
            'The Project selector owning backend is unavailable.',
          );
        }
        owner.validateProviderOwnership(provider);
        return;
      }
    }
  }

  /// The caller shares the same discovered catalog with any other component
  /// owners. Startup never rescans, compiles, or consults backend availability.
  Future<void> start(PreparedPluginCatalog catalog) {
    if (_state != ApplicationFrontendState.unconfigured) {
      throw StateError('Application frontends have already started or closed.');
    }
    _catalog = catalog;
    _generations.addAll([
      for (final installation in catalog.installations)
        if (installation.frontend != null)
          InstalledFrontendActivation._(
            installation,
            _extensions,
            _backends,
            _sessionServices,
            _taskBrowserHost,
            _consoleHost,
            _mainContentHost,
          ),
    ]);
    _setState(ApplicationFrontendState.starting);
    return _starting = _start();
  }

  Future<void> _start() async {
    for (final generation in _generations) {
      if (_state == ApplicationFrontendState.closing) return;
      await generation._start();
      _changes.add(_state);
    }
    if (_state != ApplicationFrontendState.closing) {
      _setState(ApplicationFrontendState.ready);
    }
  }

  /// Stops pending activation while keeping already-mounted inert views alive
  /// during application exit settlement. Final [close] still owns all cleanup.
  void stopStarting() {
    if (_state == ApplicationFrontendState.closing ||
        _state == ApplicationFrontendState.closed) {
      return;
    }
    _setState(ApplicationFrontendState.closing);
    for (final generation in _generations) {
      if (generation.state == InstalledFrontendState.pending ||
          generation.state == InstalledFrontendState.starting) {
        // close retains this completion/failure for final owner cleanup.
        generation.close().ignore();
      }
    }
  }

  /// Flutter awaits exit observers sequentially. Retain their mounted widgets
  /// while revoking plugin authority; detach/dispose releases the retained UI.
  void retainPresentations() {
    stopStarting();
    for (final generation in _generations) {
      generation._generation?.retainPresentations();
    }
  }

  void releasePresentations() {
    for (final generation in _generations) {
      generation._generation?.releasePresentations();
    }
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    stopStarting();
    // Revoke all factories now, including a generation still reading its bytes.
    return _closing = _close([
      ?_starting,
      for (final generation in _generations) generation.close(),
    ]);
  }

  Future<void> _close(List<Future<void>> retiring) async {
    try {
      await closeResources([
        () async => await Future.wait(retiring),
        if (_taskBrowserHost case final host?) host.close,
        if (_consoleHost case final host?) host.close,
        _mainContentHost.close,
      ]);
    } finally {
      _setState(ApplicationFrontendState.closed);
      await _changes.close();
    }
  }

  void _setState(ApplicationFrontendState state) {
    _state = state;
    _changes.add(state);
  }
}

/// Exact registrations and bytes for one installed frontend generation.
/// A view's decode/entrypoint failure remains local to PreparedFrontend.
final class InstalledFrontendActivation {
  InstalledFrontendActivation._(
    this.installation,
    this._extensions,
    this._backends,
    this._sessionServices,
    this._taskBrowserHost,
    this._consoleHost,
    this._mainContentHost,
  );

  final PreparedPluginInstallation installation;
  final ExtensionRegistry _extensions;
  final ApplicationPluginBootstrap? _backends;
  final PreparedSessionServices? _sessionServices;
  final PreparedTaskBrowserHost? _taskBrowserHost;
  final PreparedConsoleHost? _consoleHost;
  final PreparedMainContentHost _mainContentHost;
  final List<(String, ExtensionId, ExtensionRegistration)> _registrations = [];
  final List<(ExtensionRegistration, ExtensionRegistration)> _consoleCommands =
      [];
  StreamSubscription<void>? _registrationChanges;
  InstalledFrontendState _state = InstalledFrontendState.pending;
  Object? _failure;
  PreparedFrontend? _generation;
  bool _closed = false;
  Future<void>? _starting;
  Future<void>? _closing;
  Future<void>? _releasing;

  InstalledFrontendState get state => _state;
  Object? get failure => _failure;
  List<ExtensionRegistration> get registrations => List.unmodifiable([
    for (final (_, _, registration) in _registrations) registration,
  ]);

  Future<void> _start() =>
      _closed ? Future<void>.value() : _starting = _activate();

  Future<void> _activate() async {
    _state = InstalledFrontendState.starting;
    try {
      final component = installation.frontend!;
      final generation = _generation = await PreparedFrontend.load(
        File.fromUri(component.artifactUri),
      );
      if (_closed) return;
      if (generation.failure case final failure?) throw failure;
      final consoleTargets =
          <
            PreparedConsoleActionCommandExtension,
            PreparedConsolePresentation
          >{};
      for (final descriptor in component.extensions) {
        switch (descriptor) {
          case PreparedProjectSelectorExtension(
                :final library,
                :final entrypoint,
              ) ||
              PreparedCommandExtension(:final library, :final entrypoint):
            generation.validateOperation(
              library: library,
              entrypoint: entrypoint,
            );
          case PreparedConsoleActionCommandExtension():
            final targets = component.presentations
                .whereType<PreparedConsolePresentation>()
                .where(
                  (target) =>
                      target.extensionId == descriptor.consoleExtensionId,
                )
                .toList();
            if (targets.length != 1 ||
                targets.single.readOnly ||
                targets.single.actions
                        .where((action) => action.id == descriptor.actionId)
                        .length !=
                    1) {
              throw StateError(
                'A Console action Command requires one exact sibling action.',
              );
            }
            consoleTargets[descriptor] = targets.single;
        }
      }
      final consoles =
          <
            PreparedConsolePresentation,
            (ExtensionRegistration, ExtensionBinding<ConsoleContribution>)
          >{};
      for (final descriptor in component.presentations) {
        if (_closed) return;
        switch (descriptor) {
          case PreparedMainContentPresentation():
            for (final entrypoint in [
              descriptor.initialize,
              descriptor.entrypoint,
              ...descriptor.actions.map((action) => action.entrypoint),
              ...descriptor.operations.values,
            ]) {
              generation.validateOperation(
                library: descriptor.library,
                entrypoint: entrypoint,
              );
            }
            _register(
              point: mainContentContributions,
              id: descriptor.extensionId,
              contribution: (isActive) => _mainContentHost.createContribution(
                extensions: _extensions,
                installation: installation,
                generation: generation,
                descriptor: descriptor,
                isActive: isActive,
                services: _sessionServices,
              ),
            );
            if (descriptor.displaySourceFileOperation != null) {
              _register(
                point: displaySourceFileContributions,
                id: descriptor.extensionId,
                contribution: (isActive) => DisplaySourceFileContribution(
                  display: (path) {
                    _requireActive(isActive);
                    return _mainContentHost.displaySourceFile(descriptor, path);
                  },
                ),
              );
            }
          case PreparedConsolePresentation():
            // Optional read-only hosting must not retire unrelated factual
            // presentation roles. No registration means opening is unavailable.
            if (descriptor.readOnly && _consoleHost == null) continue;
            generation.validateOperation(
              library: descriptor.library,
              entrypoint: descriptor.entrypoint,
            );
            for (final action in descriptor.actions) {
              generation.validateOperation(
                library: descriptor.library,
                entrypoint: action.entrypoint,
              );
            }
            final host = _consoleHost;
            if (host == null) {
              throw StateError('Console hosting is unavailable.');
            }
            final registration = _register(
              point: consoleContributions,
              id: descriptor.extensionId,
              contribution: (isActive) => host.createContribution(
                installation: installation,
                generation: generation,
                descriptor: descriptor,
                isActive: isActive,
              ),
            );
            consoles[descriptor] = (
              registration,
              _extensions
                  .discover(consoleContributions)
                  .singleWhere(registration.owns),
            );
          case PreparedTaskBrowserPresentation():
            _register(
              point: taskBrowserContributions,
              id: descriptor.extensionId,
              contribution: (isActive) {
                late final TaskBrowserContribution contribution;
                contribution = TaskBrowserContribution(
                  displayName: descriptor.displayName,
                  createPresentation: (project) {
                    _requireActive(isActive);
                    final host = _taskBrowserHost;
                    if (host == null) {
                      throw StateError('Task Browser hosting is unavailable.');
                    }
                    return host.createPresentation(
                      generation: generation,
                      contribution: contribution,
                      descriptor: descriptor,
                      project: project,
                      isActive: isActive,
                    );
                  },
                );
                return contribution;
              },
            );
          case PreparedToolActivityPresentation():
            Widget create(
              ToolActivityInspectionSource source,
              String entrypoint,
              bool Function() isActive, {
              required bool inspection,
            }) {
              _requireActive(isActive);
              return generation.createPresentation(
                library: descriptor.library,
                entrypoint: entrypoint,
                key: ObjectKey(source),
                createBridge: () {
                  final facts = ToolActivityInspectionBridge(
                    source: source,
                    isActive: isActive,
                  );
                  if (!inspection) return facts;
                  void validate() => _requireActive(isActive);
                  OwningBackendChannel? backend;
                  // Backend observation is optional: retain canonical facts when
                  // its exact owner is absent or has already retired.
                  if (descriptor.backendServices.isNotEmpty) {
                    try {
                      backend = _backends
                          ?.backendForInstallation(installation)
                          ?.openPresentationChannel(
                            backendServices: descriptor.backendServices,
                            validatePresentation: validate,
                          );
                    } on Object {
                      backend = null;
                    }
                  }
                  validate();
                  return PreparedFrontendBridges([
                    facts,
                    if (backend != null)
                      OwningBackendBridge.channel(
                        backend,
                        validateBinding: validate,
                      )
                    else
                      OwningBackendBridge(
                        channels: const {},
                        validateBinding: validate,
                      ),
                    TerminalProjectionBridge(isActive: isActive),
                    if (_consoleHost case final host?
                        when descriptor.consoleExtensions.isNotEmpty)
                      host.createOpeningBridge(
                        installation: installation,
                        generation: generation,
                        sessionId: source.sessionId,
                        consoleExtensions: descriptor.consoleExtensions,
                        isActive: isActive,
                      )
                    else
                      ConsoleBridge(isActive: isActive),
                  ]);
                },
              );
            }

            _register(
              point: toolActivityInspectionContributions,
              id: descriptor.inspectionExtensionId,
              contribution: (isActive) => ToolActivityInspectionContribution(
                toolId: descriptor.toolId,
                createPresentation: (source) => create(
                  source,
                  descriptor.inspectionEntrypoint,
                  isActive,
                  inspection: true,
                ),
              ),
            );
            _register(
              point: toolActivityCompactPresentationContributions,
              id: descriptor.compactExtensionId,
              contribution: (isActive) =>
                  ToolActivityCompactPresentationContribution(
                    toolId: descriptor.toolId,
                    createPresentation: (source) => create(
                      source,
                      descriptor.compactEntrypoint,
                      isActive,
                      inspection: false,
                    ),
                  ),
            );
          case PreparedModelNativeActivityPresentation():
            Widget create(
              ModelNativePresentation presentation,
              String entrypoint,
              bool Function() isActive,
            ) {
              _requireActive(isActive);
              return generation.createPresentation(
                library: descriptor.library,
                entrypoint: entrypoint,
                key: ObjectKey(presentation),
                createBridge: () => ModelNativeActivityBridge(
                  presentation: presentation,
                  isActive: isActive,
                ),
              );
            }

            _register(
              point: modelNativeActivityPresentationContributions,
              id: descriptor.inspectionExtensionId,
              contribution: (isActive) =>
                  ModelNativeActivityPresentationContribution(
                    presentationKind: descriptor.presentationKind,
                    createInspection: (presentation) => create(
                      presentation,
                      descriptor.inspectionEntrypoint,
                      isActive,
                    ),
                  ),
            );
            _register(
              point: modelNativeActivityCompactPresentationContributions,
              id: descriptor.compactExtensionId,
              contribution: (isActive) =>
                  ModelNativeActivityCompactPresentationContribution(
                    presentationKind: descriptor.presentationKind,
                    createPresentation: (presentation) => create(
                      presentation,
                      descriptor.compactEntrypoint,
                      isActive,
                    ),
                  ),
            );
        }
      }
      for (final descriptor in component.extensions) {
        if (_closed) return;
        switch (descriptor) {
          case PreparedConsoleActionCommandExtension():
            final (consoleRegistration, binding) =
                consoles[consoleTargets[descriptor]]!;
            final registration = _register(
              point: commandContributions,
              id: descriptor.extensionId,
              contribution: (isActive) => _consoleHost!.createActionCommand(
                installation: installation,
                generation: generation,
                descriptor: descriptor,
                owner: binding,
                isActive: isActive,
              ),
            );
            _consoleCommands.add((consoleRegistration, registration));
            _registrationChanges ??= _extensions.changes.listen((_) {
              for (final (console, command) in _consoleCommands) {
                if (console.isClosed) unawaited(command.close());
              }
            });
          case PreparedCommandExtension():
            _register(
              point: commandContributions,
              id: descriptor.extensionId,
              contribution: (isActive) => CommandContribution(
                id: descriptor.commandId,
                label: descriptor.label,
                availability: () => isActive()
                    ? CommandAvailability.enabled
                    : CommandAvailability.disabled,
                invoke: () {
                  _requireActive(isActive);
                  return generation.invoke<void>(
                    library: descriptor.library,
                    entrypoint: descriptor.entrypoint,
                    createBridge: () => PreparedFrontendBridges(const []),
                    decodeResult: (value) {
                      if (value != null && value is! $null) {
                        throw const FormatException(
                          'A prepared Command must return void or null.',
                        );
                      }
                    },
                  );
                },
              ),
            );
          case PreparedProjectSelectorExtension():
            _register(
              point: projectSelectorContributions,
              id: descriptor.extensionId,
              contribution: (isActive) => ProjectSelectorContribution(
                displayName: descriptor.displayName,
                projectProviderId: descriptor.projectProviderId,
                selectProject: () async {
                  _requireActive(isActive);
                  late DirectoryPickerBridge bridge;
                  return generation.invoke<Uri?>(
                    library: descriptor.library,
                    entrypoint: descriptor.entrypoint,
                    createBridge: () =>
                        bridge = DirectoryPickerBridge(isActive: isActive),
                    decodeResult: (value) {
                      _requireActive(isActive);
                      bridge.validateResult();
                      final String? text = switch (value) {
                        null || $null() => null,
                        String() => value,
                        $String() => value.$value,
                        _ => throw const FormatException(
                          'A Project selector must return a URI string or null.',
                        ),
                      };
                      if (text == null) return null;
                      if (text.isEmpty || text.length > 16384) {
                        throw const FormatException(
                          'A Project selector must return a URI string or null.',
                        );
                      }
                      final uri = Uri.parse(text);
                      if (!uri.hasScheme ||
                          text.contains(RegExp(r'[\x00-\x20\x7f]')) ||
                          text.contains(RegExp(r'%(?![0-9a-fA-F]{2})'))) {
                        throw const FormatException(
                          'Invalid selected Project URI.',
                        );
                      }
                      return uri;
                    },
                  );
                },
              ),
            );
        }
      }
      _state = InstalledFrontendState.active;
    } on Object catch (error) {
      _failure = error;
      _state = InstalledFrontendState.failed;
      // Roll back every acquired registration before invalidating any view.
      try {
        await _release();
      } on Object {
        // Keep the activation failure primary. close reports cleanup failure.
      }
    }
  }

  ExtensionRegistration _register<T extends Object>({
    required ExtensionPoint<T> point,
    required ExtensionId id,
    required T Function(bool Function() isActive) contribution,
  }) {
    late final ExtensionRegistration registration;
    bool isActive() => !_closed && !registration.isClosed;
    registration = _extensions.register(
      point: point,
      id: id,
      value: contribution(isActive),
    );
    _registrations.add((point.value, id, registration));
    return registration;
  }

  static void _requireActive(bool Function() isActive) {
    if (!isActive()) {
      throw StateError('The prepared frontend contribution is retired.');
    }
  }

  /// Retires the captured point/ID registration, never a replacement binding.
  /// IDs are scoped to a point. A descriptor-derived display adapter is owned
  /// by its Main Content contribution; Console action Commands depend on their
  /// exact Console registration, never the other way around.
  Future<void> retire<T extends Object>(
    ExtensionPoint<T> point,
    ExtensionId id,
  ) async {
    final ownsDisplay =
        point.value == mainContentContributions.value &&
        installation.frontend!.presentations.any(
          (descriptor) =>
              descriptor is PreparedMainContentPresentation &&
              descriptor.extensionId == id &&
              descriptor.displaySourceFileOperation != null,
        );
    final retiring = [
      for (final (registeredPoint, registeredId, registration)
          in _registrations)
        if (registeredId == id &&
            (registeredPoint == point.value ||
                (ownsDisplay &&
                    registeredPoint == displaySourceFileContributions.value)))
          registration,
    ];
    await Future.wait([
      for (final (console, command) in _consoleCommands)
        if (retiring.contains(console)) command.close(),
      for (final registration in retiring) registration.close(),
    ]);
    if (point.value == mainContentContributions.value) {
      for (final descriptor in installation.frontend!.presentations) {
        if (descriptor is PreparedMainContentPresentation &&
            descriptor.extensionId == id) {
          _mainContentHost.retire(descriptor);
        }
      }
    }
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    _state = InstalledFrontendState.closing;
    return _closing = _close();
  }

  Future<void> _close() async {
    try {
      await _starting;
      await _release();
    } finally {
      _state = InstalledFrontendState.closed;
    }
  }

  Future<void> _release() => _releasing ??= _releaseResources();

  Future<void> _releaseResources() async {
    try {
      await Future.wait([
        for (final (_, _, registration) in _registrations.reversed)
          registration.close(),
        if (_registrationChanges case final changes?) changes.cancel(),
      ]);
    } finally {
      await closeResources([
        () async => _generation?.invalidate(),
        for (final descriptor in installation.frontend!.presentations)
          if (descriptor is PreparedMainContentPresentation)
            () async => _mainContentHost.retire(descriptor),
      ]);
    }
  }
}
