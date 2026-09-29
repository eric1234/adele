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
import 'session_presentation_lifecycle_bridge.dart';

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

  /// Reattachment must use the backend strategy already captured by execution,
  /// not a same-ID replacement or the lifetime of an earlier frontend view.
  void validateController(SessionExecutionController controller) {
    validate();
    if (controller.isClosed ||
        controller.session.strategyId != strategy.strategyId) {
      throw StateError('The Session execution owner is unavailable.');
    }
    final captured =
        controller.strategy ??
        (controller.isRunning || controller.isAdvancing
            ? controller.capturedStrategy
            : null);
    if (captured == null) return;
    captured.validateBinding();
    if (!captured.binding.isSameRegistration(strategy.binding)) {
      throw StateError(
        'The Session has a different captured strategy binding.',
      );
    }
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
    this.lookupControllerForSession,
  });

  final ExtensionRegistry extensions;
  final ApplicationPluginBootstrap backends;
  final SessionExecutionController Function(Session) controllerForSession;
  final SessionExecutionController? Function(Session)?
  lookupControllerForSession;
  final bool Function(Session, InspectionTarget) inspectActivity;
  // Metadata must not keep retired contribution generations alive.
  final _metadata =
      Expando<(PreparedPluginInstallation, PreparedSessionPresentation)>();
  final Map<Session, _SessionPresentationBinding> _sessions = {};
  bool _closed = false;

  void registerMetadata(
    SessionPresentationContribution contribution,
    PreparedPluginInstallation installation,
    PreparedSessionPresentation descriptor,
  ) {
    _metadata[contribution] = (installation, descriptor);
  }

  SessionPresentationSelection resolve(
    ExtensionBinding<SessionPresentationContribution> presentation, {
    Session? session,
  }) {
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
    final selection = SessionPresentationSelection._(
      presentation: presentation,
      strategy: strategy,
      pinStrategy: pin,
      backend: backend,
    )..validate();
    if (session != null) {
      if (session.strategyId != strategy.strategyId) {
        throw StateError('Presentation belongs to another Session strategy.');
      }
      final controller = lookupControllerForSession?.call(session);
      if (controller != null) {
        if (!identical(controller.session, session)) {
          throw StateError('Execution belongs to another canonical Session.');
        }
        selection.validateController(controller);
      }
    }
    return selection;
  }

  void bind(Session session, SessionPresentationSelection selection) {
    selection.validate();
    if (_closed || session.strategyId != selection.strategy.strategyId) {
      throw StateError('Cannot bind this Session presentation.');
    }
    unbind(session);
    _sessions[session] = _SessionPresentationBinding(selection);
  }

  /// Await local presentation state before changing views, not Run settlement.
  /// No hook means no pending presentation state, including absent native views.
  Future<void> prepareToDeactivate(Session session) async {
    final binding = _sessions[session];
    await binding?.lifecycle?.prepareToDeactivate();
  }

  /// Revoke every action from this binding, even if the same Session is reopened.
  void unbind(Session session) {
    _sessions.remove(session)?.bridges?.invalidate();
  }

  Widget createPresentation({
    required PreparedFrontend generation,
    required SessionPresentationContribution contribution,
    required PreparedSessionPresentation descriptor,
    required Session session,
    required bool Function() isActive,
  }) {
    final binding = _sessions[session];
    final selection = binding?.selection;
    if (_closed ||
        !isActive() ||
        selection == null ||
        !identical(selection.presentation.value, contribution)) {
      throw StateError('No exact presentation binding for this Session.');
    }
    selection.presentation.validate();
    final controller = controllerForSession(session);
    if (!identical(controller.session, session)) {
      throw StateError('Execution belongs to another canonical Session.');
    }
    selection.validateController(controller);
    bool available() {
      if (_closed ||
          !identical(_sessions[session], binding) ||
          !isActive() ||
          controller.isClosed) {
        return false;
      }
      selection.validateController(controller);
      return true;
    }

    void validateBinding() {
      if (!available()) throw StateError('Session presentation is retired.');
    }

    return generation.createPresentation(
      library: descriptor.library,
      entrypoint: descriptor.entrypoint,
      key: ObjectKey(binding),
      createBridge: () {
        validateBinding();
        binding!.bridges?.invalidate();
        late final SessionPresentationLifecycleBridge lifecycle;
        lifecycle = SessionPresentationLifecycleBridge(
          isActive: available,
          onInvalidate: () {
            if (identical(binding.lifecycle, lifecycle)) {
              binding.lifecycle = null;
              binding.bridges = null;
            }
          },
        );
        binding.lifecycle = lifecycle;
        return binding.bridges = PreparedFrontendBridges([
          lifecycle,
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
              validateBinding: validateBinding,
            )
          else
            OwningBackendBridge(
              channels: const {},
              validateBinding: validateBinding,
            ),
        ]);
      },
    );
  }

  Future<void> close() async {
    _closed = true;
    for (final session in _sessions.keys.toList()) {
      unbind(session);
    }
  }
}

final class _SessionPresentationBinding {
  _SessionPresentationBinding(this.selection);

  final SessionPresentationSelection selection;
  SessionPresentationLifecycleBridge? lifecycle;
  PreparedFrontendBridges? bridges;
}
