import 'package:adele_core_extensions/commands.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/widgets.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../core/application_plugin_bootstrap.dart';
import '../core/product_lifecycle.dart';
import '../terminal/environment_terminal_owner.dart';
import '../terminal/terminal_console_content.dart';
import '../ui/console/console_controller.dart';
import 'console_bridge.dart';
import 'environment_terminal_bridge.dart';
import 'owning_backend_bridge.dart';
import 'prepared_frontend.dart';
import 'structured_bridge_data.dart';
import 'terminal_projection_bridge.dart';

/// Prepared operations admit content; presentations never own that content's
/// resource or retained policy. No evaluator callback survives an operation.
base class PreparedConsoleHost {
  PreparedConsoleHost({
    required this.store,
    required this.terminals,
    required this.extensions,
    required this.controller,
    this.backends,
  });

  final InMemoryProductStore store;
  final EnvironmentTerminalCoordinator terminals;
  final ExtensionRegistry extensions;
  final ConsoleController controller;
  final ApplicationPluginBootstrap? backends;
  final _metadata = Expando<(PreparedPluginInstallation, PreparedFrontend)>();
  final Set<_ConsolePresentationBridge> _presentations = {};
  bool _closed = false;
  int _terminalSequence = 0;

  /// Passive canonical lookup, deliberately not the Task's primary Environment.
  Environment? environmentForSession(Session session) {
    if (_closed || !identical(store.session(session.id), session)) return null;
    final task = store.task(session.taskId);
    final authority = store.sessionAuthority(session.id);
    if (task == null ||
        store.project(task.projectId) == null ||
        authority == null ||
        authority.sessionId != session.id ||
        authority.taskId != task.id) {
      return null;
    }
    final environment = store.environment(authority.environmentId);
    return environment != null && environment.taskId == task.id
        ? environment
        : null;
  }

  ConsoleContribution createContribution({
    required PreparedPluginInstallation installation,
    required PreparedFrontend generation,
    required PreparedConsolePresentation descriptor,
    required bool Function() isActive,
  }) {
    final contribution = ConsoleContribution(
      openPrepared: descriptor.readOnly
          ? (access, content) async {
              final session = access.session;
              if (_closed ||
                  !access.isActive ||
                  !isActive() ||
                  !_canonical(session)) {
                throw StateError('Console content is unavailable.');
              }
              final state = ConsoleContentState(content);
              var released = false;
              bool retainedActive() =>
                  !_closed && !released && isActive() && _canonical(session);
              void validateContent() {
                if (!retainedActive()) {
                  throw StateError('Console content is retired.');
                }
              }

              // Capture once at admission, never select a replacement backend on remount.
              OwningBackendChannel? backend;
              InstalledBackendActivation? backendOwner;
              if (descriptor.backendServices.isNotEmpty) {
                try {
                  final owner = backends?.backendForInstallation(installation);
                  backend = owner?.openPresentationChannel(
                    backendServices: descriptor.backendServices,
                    validatePresentation: validateContent,
                  );
                  if (backend != null) backendOwner = owner;
                } on Object {
                  // Factual content remains available; backend access stays unavailable.
                }
              }
              access.open(
                ConsoleContent(
                  metadata: content.metadata,
                  keepAlive: descriptor.keepAlive,
                  isEligible: (candidate) =>
                      identical(candidate, session) && _canonical(session),
                  closeAdvice: () => const ConsoleCloseAdvice.noConfirmation(),
                  release: () async {
                    released = true;
                    state.clear();
                    return ConsoleCleanupResult();
                  },
                  createPresentation: (presentation) {
                    bool available() {
                      if (!retainedActive() || !presentation.isActive) {
                        return false;
                      }
                      try {
                        backend?.validate();
                        return true;
                      } on Object {
                        return false;
                      }
                    }

                    void validateView() {
                      if (!available()) {
                        throw StateError('Console view is retired.');
                      }
                    }

                    validateView();
                    return generation.createPresentation(
                      library: descriptor.library,
                      entrypoint: descriptor.entrypoint,
                      key: ObjectKey(presentation),
                      createBridge: () {
                        validateView();
                        final bridges = <PreparedFrontendBridge>[
                          TerminalProjectionBridge(
                            isActive: available,
                            presentation: presentation,
                            retention: state.projection,
                          ),
                          ConsoleBridge(
                            isActive: available,
                            content: state,
                            presentation: presentation,
                          ),
                          if (backend case final channel?)
                            OwningBackendBridge.channel(
                              channel,
                              validateBinding: validateView,
                            )
                          else
                            OwningBackendBridge(
                              channels: const {},
                              validateBinding: validateView,
                            ),
                        ];
                        late final _ConsolePresentationBridge bridge;
                        bridge = _ConsolePresentationBridge(
                          presentation,
                          bridges,
                          () => _presentations.remove(bridge),
                          backendOwner,
                        );
                        _presentations.add(bridge);
                        return bridge;
                      },
                    );
                  },
                ),
              );
            }
          : null,
      actions: [
        for (final action in descriptor.actions)
          ConsoleCreationAction(
            id: action.id,
            label: action.label,
            create: (access) async {
              if (_closed || !access.isActive || !isActive()) {
                throw StateError('Console creation is unavailable.');
              }
              // Capture scope before the evaluator or provider can await. Once
              // admitted, navigation must not retarget or orphan the result.
              final environment = environmentForSession(access.session);
              await generation.invoke<void>(
                library: descriptor.library,
                entrypoint: action.entrypoint,
                createBridge: () => EnvironmentTerminalBridge(
                  isActive: () => !_closed && access.isActive && isActive(),
                  create: (policy) async {
                    if (environment == null ||
                        environmentForSession(access.session)?.id !=
                            environment.id) {
                      throw StateError('Session Environment is unavailable.');
                    }
                    await TerminalConsoleContent.open(
                      coordinator: terminals,
                      environmentId: environment.id,
                      access: access,
                      policy: policy,
                      fallbackTitle: '${policy.label} ${++_terminalSequence}',
                      generation: generation,
                      descriptor: descriptor,
                      isActive: () => !_closed && isActive(),
                      isEligible: (session) =>
                          environmentForSession(session)?.id == environment.id,
                    );
                  },
                ),
                decodeResult: (value) {
                  final result = copyStructuredBridgeData(value);
                  if (result is! List ||
                      result.length != 2 ||
                      result[0] != true ||
                      result[1] != null) {
                    throw StateError('Console action did not complete.');
                  }
                },
              );
            },
          ),
      ],
    );
    _metadata[contribution] = (installation, generation);
    return contribution;
  }

  bool _canonical(Session session) =>
      identical(store.session(session.id), session) &&
      store.task(session.taskId) != null &&
      store.project(store.task(session.taskId)!.projectId) != null;

  /// Adapts one captured sibling registration, not a global action-ID lookup.
  CommandContribution createActionCommand({
    required PreparedPluginInstallation installation,
    required PreparedFrontend generation,
    required PreparedConsoleActionCommandExtension descriptor,
    required ExtensionBinding<ConsoleContribution> owner,
    required bool Function() isActive,
  }) {
    final contribution = owner.value;
    final metadata = _metadata[contribution];
    if (metadata == null ||
        !identical(metadata.$1, installation) ||
        !identical(metadata.$2, generation) ||
        owner.id != descriptor.consoleExtensionId) {
      throw StateError('The Console action Command target is unavailable.');
    }
    final action = contribution.actions.singleWhere(
      (action) => action.id == descriptor.actionId,
    );
    CommandAvailability availability() {
      final session = controller.session;
      if (_closed ||
          !isActive() ||
          !controller.isExactActionLive(owner, action) ||
          session == null ||
          !_canonical(session)) {
        return CommandAvailability.hidden;
      }
      if (environmentForSession(session) == null ||
          controller.isExactActionPending(owner, action)) {
        return CommandAvailability.disabled;
      }
      return CommandAvailability.enabled;
    }

    return CommandContribution(
      id: descriptor.commandId,
      label: action.label,
      availability: availability,
      invoke: () {
        if (availability() != CommandAvailability.enabled) {
          throw CommandUnavailable(descriptor.commandId);
        }
        return controller.invokeExactAction(owner, action);
      },
    );
  }

  /// Captures exact declared registrations at presentation creation. Retirement
  /// or replacement never changes what this presentation may open.
  PreparedFrontendBridge createOpeningBridge({
    required PreparedPluginInstallation installation,
    required PreparedFrontend generation,
    required SessionId sessionId,
    required Iterable<ExtensionId> consoleExtensions,
    required bool Function() isActive,
  }) {
    final session = store.session(sessionId);
    final allowed = consoleExtensions.toSet();
    final bindings = <String, ExtensionBinding<ConsoleContribution>>{};
    for (final binding in extensions.discover(consoleContributions)) {
      final metadata = _metadata[binding.value];
      if (allowed.contains(binding.id) &&
          metadata != null &&
          identical(metadata.$1, installation) &&
          identical(metadata.$2, generation) &&
          binding.value.openPrepared != null) {
        bindings[binding.id.value] = binding;
      }
    }
    return ConsoleBridge(
      isActive: () =>
          !_closed && isActive() && session != null && _canonical(session),
      open: (id, content) {
        final binding = bindings[id];
        if (_closed ||
            session == null ||
            !_canonical(session) ||
            binding == null) {
          throw StateError('Declared console content is unavailable.');
        }
        return controller.openOrFocus(
          owner: binding,
          session: session,
          descriptor: content,
        );
      },
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final presentations = _presentations.toList();
    controller.unmountPresentation();
    // Exit-retained views may already have detached their resident listeners.
    // Closing this owner ends that working set as well as ordinary residents.
    Object? failure;
    StackTrace? failureStack;
    for (final bridge in presentations) {
      try {
        // The owning host can close before its Flutter parent unmounts. End the
        // loaded evaluator as well as bridge access in that surviving subtree.
        bridge.retire();
      } on Object catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }
}

/// Constructed only when PreparedFrontend loads the view, so missing bytecode
/// cannot leave an unattached access listener. Its cleanup also runs on eval
/// configuration/build failure, independently of eventual widget disposal.
final class _ConsolePresentationBridge
    implements
        PreparedFrontendBridge,
        PreparedFrontendFailureSource,
        PreparedFrontendRetainable {
  _ConsolePresentationBridge(
    this._presentation,
    this._bridges,
    this._onRelease,
    this._backendOwner,
  ) : _combined = PreparedFrontendBridges(_bridges) {
    _presentation.changes.addListener(_changed);
  }

  final ConsolePresentationAccess _presentation;
  final List<PreparedFrontendBridge> _bridges;
  final PreparedFrontendBridges _combined;
  final VoidCallback _onRelease;
  final InstalledBackendActivation? _backendOwner;
  VoidCallback? _detachBackend;
  VoidCallback? _onFailure;
  bool _invalidated = false;

  @override
  String get identifier => _combined.identifier;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) =>
      _combined.configureForCompile(registry);

  @override
  void configureForRuntime(Runtime runtime) {
    if (_invalidated || !_presentation.isActive) {
      throw StateError('Console view is retired.');
    }
    _detachBackend = _backendOwner?.onRetire(retire);
    _combined.configureForRuntime(runtime);
  }

  @override
  set onFailure(VoidCallback? callback) {
    _onFailure = callback;
    _combined.onFailure = callback;
  }

  void retire() {
    try {
      invalidate();
    } finally {
      _onFailure?.call();
    }
  }

  void _changed() {
    if (!_presentation.isActive) invalidate();
  }

  @override
  void retainPresentation() {
    _presentation.changes.removeListener(_changed);
    _detachBackend?.call();
    _detachBackend = null;
    _combined.retainPresentation();
  }

  @override
  void invalidate() {
    if (_invalidated) return;
    _invalidated = true;
    _presentation.changes.removeListener(_changed);
    _detachBackend?.call();
    _detachBackend = null;
    _onRelease();
    Object? failure;
    StackTrace? failureStack;
    for (final bridge in _bridges) {
      try {
        // Projection invalidation checkpoints native bounded state before it
        // disposes the surface; no revoked evaluator callback is required.
        bridge.invalidate();
      } on Object catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }
}
