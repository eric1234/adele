import 'dart:async';
import 'dart:io';

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/widgets.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../core/resource_cleanup.dart';
import 'directory_picker_bridge.dart';
import 'model_native_activity_bridge.dart';
import 'prepared_frontend.dart';
import 'prepared_session_host.dart';
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
    PreparedSessionHost? sessionHost,
  }) : _extensions = extensions,
       _sessionHost = sessionHost;

  final ExtensionRegistry _extensions;
  final PreparedSessionHost? _sessionHost;
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
            _sessionHost,
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
        if (_sessionHost case final host?) host.close,
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
    this._sessionHost,
  );

  final PreparedPluginInstallation installation;
  final ExtensionRegistry _extensions;
  final PreparedSessionHost? _sessionHost;
  final List<(String, ExtensionId, ExtensionRegistration)> _registrations = [];
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
      for (final descriptor in component.extensions) {
        switch (descriptor) {
          case PreparedProjectSelectorExtension():
            generation.validateOperation(
              library: descriptor.library,
              entrypoint: descriptor.entrypoint,
            );
        }
      }
      for (final descriptor in component.presentations) {
        if (_closed) return;
        switch (descriptor) {
          case PreparedSessionPresentation():
            _register(
              point: sessionPresentationContributions,
              id: descriptor.extensionId,
              contribution: (isActive) {
                late final SessionPresentationContribution contribution;
                contribution = SessionPresentationContribution(
                  strategyId: descriptor.strategyId,
                  displayName: descriptor.displayName,
                  createPresentation: (session) {
                    _requireActive(isActive);
                    final host = _sessionHost;
                    if (host == null) {
                      throw StateError('Session hosting is unavailable.');
                    }
                    return host.createPresentation(
                      generation: generation,
                      contribution: contribution,
                      descriptor: descriptor,
                      session: session,
                      isActive: isActive,
                    );
                  },
                );
                _sessionHost?.registerMetadata(
                  contribution,
                  installation,
                  descriptor,
                );
                return contribution;
              },
            );
          case PreparedToolActivityPresentation():
            Widget create(
              ToolActivityInspectionSource source,
              String entrypoint,
              bool Function() isActive,
            ) {
              _requireActive(isActive);
              return generation.createPresentation(
                library: descriptor.library,
                entrypoint: entrypoint,
                key: ObjectKey(source),
                createBridge: () => ToolActivityInspectionBridge(
                  source: source,
                  isActive: isActive,
                ),
              );
            }

            _register(
              point: toolActivityInspectionContributions,
              id: descriptor.inspectionExtensionId,
              contribution: (isActive) => ToolActivityInspectionContribution(
                toolId: descriptor.toolId,
                createPresentation: (source) =>
                    create(source, descriptor.inspectionEntrypoint, isActive),
              ),
            );
            _register(
              point: toolActivityCompactPresentationContributions,
              id: descriptor.compactExtensionId,
              contribution: (isActive) =>
                  ToolActivityCompactPresentationContribution(
                    toolId: descriptor.toolId,
                    createPresentation: (source) =>
                        create(source, descriptor.compactEntrypoint, isActive),
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
          case PreparedProjectSelectorExtension():
            _register(
              point: projectSelectorContributions,
              id: descriptor.extensionId,
              contribution: (isActive) => ProjectSelectorContribution(
                displayName: descriptor.displayName,
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

  void _register<T extends Object>({
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
  }

  static void _requireActive(bool Function() isActive) {
    if (!isActive()) {
      throw StateError('The prepared frontend contribution is retired.');
    }
  }

  /// Retires the captured point/ID registration, never a replacement binding.
  /// IDs are scoped to a point; equal IDs at sibling points remain independent.
  Future<void> retire<T extends Object>(
    ExtensionPoint<T> point,
    ExtensionId id,
  ) async {
    await Future.wait([
      for (final (registeredPoint, registeredId, registration)
          in _registrations)
        if (registeredPoint == point.value && registeredId == id)
          registration.close(),
    ]);
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
      ]);
    } finally {
      _generation?.invalidate();
    }
  }
}
