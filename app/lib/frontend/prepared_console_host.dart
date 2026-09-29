import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
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
final class PreparedConsoleHost {
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
              if (descriptor.backendServices.isNotEmpty) {
                try {
                  backend = backends
                      ?.backendForInstallation(installation)
                      ?.openPresentationChannel(
                        backendServices: descriptor.backendServices,
                        validatePresentation: validateContent,
                      );
                } on Object {
                  // Factual content remains available; backend access stays unavailable.
                }
              }
              access.open(
                ConsoleContent(
                  metadata: content.metadata,
                  isEligible: (candidate) =>
                      identical(candidate, session) && _canonical(session),
                  closeAdvice: () => const ConsoleCloseAdvice.noConfirmation(),
                  release: () async {
                    released = true;
                    state.clear();
                    return ConsoleCleanupResult();
                  },
                  createPresentation: (presentation) {
                    bool available() =>
                        retainedActive() && presentation.isActive;
                    void validateView() {
                      if (!available()) {
                        throw StateError('Console view is retired.');
                      }
                    }

                    return generation.createPresentation(
                      library: descriptor.library,
                      entrypoint: descriptor.entrypoint,
                      key: ObjectKey(presentation),
                      createBridge: () => PreparedFrontendBridges([
                        ConsoleBridge(isActive: available, content: state),
                        TerminalProjectionBridge(
                          isActive: available,
                          retention: state.projection,
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
                      ]),
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

  Future<void> close() async => _closed = true;
}
