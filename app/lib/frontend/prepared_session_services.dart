import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../core/application_plugin_bootstrap.dart';
import '../ui/execution/session_execution_controller.dart';
import '../ui/inspection/activity_inspection_selection.dart';
import 'owning_backend_bridge.dart';
import 'prepared_frontend.dart';
import 'session_execution_bridge.dart';
import 'session_execution_source.dart';

/// Opt-in services for an actual presentation, never a renderer selection or an
/// execution owner. Registration and backend origins retain their exact identity.
final class PreparedSessionServices {
  PreparedSessionServices({
    required this.extensions,
    required this.backends,
    required this.controllerForSession,
    required this.inspectActivity,
    required this.isCurrent,
    this.isInteractive,
    this.lookupControllerForSession,
  });

  final ExtensionRegistry extensions;
  final ApplicationPluginBootstrap backends;
  final SessionExecutionController Function(
    Session,
    ResolvedOrchestrationStrategy?,
  )
  controllerForSession;
  final SessionExecutionController? Function(Session)?
  lookupControllerForSession;
  final bool Function(Session, InspectionTarget) inspectActivity;
  final bool Function(Session) isCurrent;
  final bool Function(Session)? isInteractive;
  final _metadata =
      Expando<(PreparedPluginInstallation, PreparedMainContentPresentation)>();

  void registerMetadata(
    MainContentContribution contribution,
    PreparedPluginInstallation installation,
    PreparedMainContentPresentation descriptor,
  ) {
    _metadata[contribution] = (installation, descriptor);
  }

  PreparedFrontendBridge bind(
    ExtensionBinding<MainContentContribution> view, {
    required Session session,
    required bool Function() isActive,
  }) {
    void validateView() {
      view.validate();
      if (!isActive() ||
          !isCurrent(session) ||
          !extensions
              .discover(mainContentContributions)
              .any(view.isSameRegistration)) {
        throw StateError('The exact Main Content presentation is unavailable.');
      }
    }

    validateView();
    final metadata = _metadata[view.value];
    if (metadata == null) {
      throw StateError('No prepared metadata for this exact contribution.');
    }
    final (installation, descriptor) = metadata;
    if (view.id != descriptor.extensionId) {
      throw StateError(
        'Presentation metadata belongs to another registration.',
      );
    }
    final owning =
        descriptor.strategyAffinity == PreparedStrategyAffinity.owningBackend;
    var controller = descriptor.sessionExecution || owning
        ? lookupControllerForSession?.call(session)
        : null;
    if (controller != null && !identical(controller.session, session)) {
      throw StateError('Execution belongs to another canonical Session.');
    }
    // Never replace a live/pinned owner's strategy with a same-ID registration.
    final captured =
        controller?.strategy ??
        (controller != null && (controller.isRunning || controller.isAdvancing)
            ? controller.capturedStrategy
            : null);
    final strategy = descriptor.sessionExecution || owning
        ? captured ??
              OrchestrationStrategyResolver(
                extensions,
              ).resolve(session.strategyId)
        : null;
    strategy?.validateBinding();
    if (strategy != null &&
        !extensions
            .discover(orchestrationStrategyContributions)
            .any(strategy.binding.isSameRegistration)) {
      throw StateError('The strategy belongs to another registry.');
    }
    if (strategy != null && strategy.strategyId != session.strategyId) {
      throw StateError('Execution belongs to another Session strategy.');
    }

    OwningBackendChannel? backend;
    if (owning || descriptor.backendServices.isNotEmpty) {
      final owner = backends.backendForInstallation(installation);
      if (owner == null) throw StateError('The owning backend is unavailable.');
      backend = owner.openChannel(
        backendServices: descriptor.backendServices,
        strategyAffinity: descriptor.strategyAffinity,
        strategyBinding: strategy?.binding,
        validatePresentation: validateView,
      );
    }
    if (descriptor.sessionExecution) {
      controller ??= controllerForSession(session, owning ? strategy : null);
    }
    void validate() {
      validateView();
      backend?.validate();
      if (controller != null && (descriptor.sessionExecution || owning)) {
        final owner = controller;
        if (owner.isClosed || !identical(owner.session, session)) {
          throw StateError('The Session execution owner is unavailable.');
        }
        final pin =
            owner.strategy ??
            (owner.isRunning || owner.isAdvancing
                ? owner.capturedStrategy
                : null);
        pin?.validateBinding();
        strategy!.validateBinding();
        if (pin != null && !pin.binding.isSameRegistration(strategy.binding)) {
          throw StateError(
            'The Session has a different captured strategy binding.',
          );
        }
      }
    }

    validate();
    bool available() {
      validate();
      return true;
    }

    return PreparedFrontendBridges([
      if (descriptor.sessionExecution)
        SessionExecutionBridge(
          source: SessionExecutionPresentationSource(
            controller: controller!,
            extensions: extensions,
            isActive: available,
            isInteractive: () => (isInteractive ?? isCurrent)(session),
            expectedStrategy: owning ? strategy : null,
            inspect: inspectActivity,
          ),
          isActive: available,
        ),
      if (backend != null)
        OwningBackendBridge.channel(backend, validateBinding: validate),
    ]);
  }
}
