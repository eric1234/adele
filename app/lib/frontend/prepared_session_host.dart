import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../core/application_plugin_bootstrap.dart';
import '../ui/execution/session_execution_controller.dart';
import '../ui/inspection/activity_inspection_selection.dart';
import 'owning_backend_bridge.dart';
import 'prepared_frontend.dart';
import 'session_execution_bridge.dart';
import 'session_execution_source.dart';

/// The exact pre-publication choice, including any owning-backend affinity.
final class SessionPresentationSelection {
  SessionPresentationSelection._({
    required this.presentation,
    required this.strategy,
    required this.pinStrategy,
    required this.backend,
  });

  final ExtensionBinding<SessionPresentationContribution> presentation;
  final ResolvedOrchestrationStrategy strategy;
  final bool pinStrategy;
  final OwningBackendChannel? backend;

  void validate() {
    presentation.validate();
    strategy.validateBinding();
    backend?.validate();
  }
}

/// One generic Session hosting path. Metadata selects ABI and affinity, not a
/// named host adapter or a strategy-specific controller implementation.
final class PreparedSessionHost {
  PreparedSessionHost({
    required this.extensions,
    required this.backends,
    required this.controllerForSession,
    required this.inspectActivity,
  });

  final ExtensionRegistry extensions;
  final ApplicationPluginBootstrap backends;
  final SessionExecutionController Function(Session) controllerForSession;
  final bool Function(Session, InspectionTarget) inspectActivity;
  final Map<
    SessionPresentationContribution,
    (PreparedPluginInstallation, PreparedSessionPresentation)
  >
  _metadata = {};
  final Map<Session, SessionPresentationSelection> _sessions = {};
  bool _closed = false;

  void registerMetadata(
    SessionPresentationContribution contribution,
    PreparedPluginInstallation installation,
    PreparedSessionPresentation descriptor,
  ) {
    _metadata[contribution] = (installation, descriptor);
  }

  SessionPresentationSelection resolve(
    ExtensionBinding<SessionPresentationContribution> presentation,
  ) {
    if (_closed) throw StateError('Session hosting is closed.');
    presentation.validate();
    final exact = SessionPresentationResolver(
      extensions,
    ).resolve(presentation.value.strategyId);
    if (!presentation.isSameRegistration(exact)) {
      throw StateError('The Session presentation choice is no longer current.');
    }
    final strategy = OrchestrationStrategyResolver(
      extensions,
    ).resolve(presentation.value.strategyId);
    OwningBackendChannel? backend;
    bool pin = false;
    if (_metadata[presentation.value] case final metadata?) {
      final (installation, descriptor) = metadata;
      pin =
          descriptor.strategyAffinity == PreparedStrategyAffinity.owningBackend;
      if (pin || descriptor.backendServices.isNotEmpty) {
        final owner = backends.backendForInstallation(installation);
        if (owner == null) {
          throw StateError('The owning backend is unavailable.');
        }
        backend = owner.openChannel(
          presentation: descriptor,
          strategyBinding: strategy.binding,
          validatePresentation: () {
            if (_closed) throw StateError('Session hosting is closed.');
            presentation.validate();
          },
        );
      }
    }
    return SessionPresentationSelection._(
      presentation: presentation,
      strategy: strategy,
      pinStrategy: pin,
      backend: backend,
    )..validate();
  }

  void bind(Session session, SessionPresentationSelection selection) {
    selection.validate();
    if (_closed || session.strategyId != selection.strategy.strategyId) {
      throw StateError('Cannot bind this Session presentation.');
    }
    _sessions[session] = selection;
  }

  Widget createPresentation({
    required PreparedFrontend generation,
    required SessionPresentationContribution contribution,
    required PreparedSessionPresentation descriptor,
    required Session session,
    required bool Function() isActive,
  }) {
    final selection = _sessions[session];
    if (_closed ||
        !isActive() ||
        selection == null ||
        !identical(selection.presentation.value, contribution)) {
      throw StateError('No exact presentation binding for this Session.');
    }
    selection.presentation.validate();
    final controller = controllerForSession(session);
    bool available() => !_closed && isActive() && !controller.isClosed;
    return generation.createPresentation(
      library: descriptor.library,
      entrypoint: descriptor.entrypoint,
      key: ObjectKey(session),
      createBridge: () => PreparedFrontendBridges([
        SessionExecutionBridge(
          source: SessionExecutionPresentationSource(
            controller: controller,
            extensions: extensions,
            isActive: available,
            inspect: inspectActivity,
          ),
          isActive: available,
        ),
        if (selection.backend case final backend?)
          OwningBackendBridge.channel(
            backend,
            validateBinding: () {
              if (!available()) {
                throw StateError('Session presentation is retired.');
              }
            },
          )
        else
          OwningBackendBridge(
            channels: const {},
            validateBinding: () {
              if (!available()) {
                throw StateError('Session presentation is retired.');
              }
            },
          ),
      ]),
    );
  }

  Future<void> close() async {
    _closed = true;
    _metadata.clear();
    _sessions.clear();
  }
}
