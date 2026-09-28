import 'dart:async';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../frontend/environment_terminal_bridge.dart';
import '../frontend/prepared_frontend.dart';
import '../frontend/terminal_surface_bridge.dart';
import 'environment_terminal_owner.dart';

/// Native mechanism for contribution-supplied terminal policy. It retains only
/// validated values and the exact owner, never callbacks into a disposed EVC.
final class TerminalConsoleContent {
  TerminalConsoleContent._({
    required this.coordinator,
    required this.owner,
    required this.policy,
    required this.fallbackTitle,
  });

  final EnvironmentTerminalCoordinator coordinator;
  final EnvironmentTerminalOwner owner;
  final TerminalContentPolicy policy;
  final String fallbackTitle;
  late final ConsoleTabRegistration _tab;
  void Function()? _detach;
  Future<ConsoleCleanupResult>? _releasing;

  static Future<void> open({
    required EnvironmentTerminalCoordinator coordinator,
    required EnvironmentId environmentId,
    required ConsoleCreationAccess access,
    required TerminalContentPolicy policy,
    required String fallbackTitle,
    required PreparedFrontend generation,
    required PreparedConsolePresentation descriptor,
    required bool Function() isActive,
    required bool Function(Session) isEligible,
  }) async {
    if (!access.isActive || !isActive()) {
      throw StateError('Console creation is retired.');
    }
    final owner = coordinator.create(
      environmentId,
      request: EnvironmentTerminalRequest(
        launchKind: EnvironmentTerminalLaunchKind.defaultShell,
        program: null,
        arguments: const [],
        relativeWorkingDirectory: '',
        dimensions: EnvironmentTerminalDimensions(columns: 80, rows: 24),
      ),
    );
    final retained = TerminalConsoleContent._(
      coordinator: coordinator,
      owner: owner,
      policy: policy,
      fallbackTitle: fallbackTitle,
    );
    try {
      retained._tab = access.open(
        ConsoleContent(
          metadata: retained._metadata,
          isEligible: isEligible,
          closeAdvice: () => retained._closeAdvice,
          release: retained.release,
          createPresentation: (presentation) => generation.createPresentation(
            library: descriptor.library,
            entrypoint: descriptor.entrypoint,
            key: ObjectKey(presentation),
            createBridge: () => TerminalSurfaceBridge(
              surface: owner.surface,
              isActive: () =>
                  presentation.isActive && retained._tab.isActive && isActive(),
            ),
          ),
        ),
      );
      if (!retained._tab.isActive) {
        await retained.release();
        return;
      }
      retained._detach = owner.observe(retained._changed);
      await owner.open();
      // open() settling is not proof of launch. Metadata reflects actual state.
      retained._changed();
    } on Object {
      await retained.release();
      rethrow;
    }
  }

  ConsoleMetadata get _metadata {
    final (status, description) = switch (owner.state) {
      EnvironmentTerminalState.idle || EnvironmentTerminalState.opening => (
        ConsoleStatus.opening,
        'Opening shell...',
      ),
      EnvironmentTerminalState.running => (
        ConsoleStatus.running,
        'Interactive shell; activity is unknown.',
      ),
      EnvironmentTerminalState.completed when owner.cleanupPending => (
        ConsoleStatus.completed,
        'Shell finished; releasing resources...',
      ),
      EnvironmentTerminalState.completed when !owner.cleanupSucceeded => (
        ConsoleStatus.failed,
        'Shell finished, but cleanup is unconfirmed.',
      ),
      EnvironmentTerminalState.completed => (
        ConsoleStatus.completed,
        'Shell finished.',
      ),
      EnvironmentTerminalState.disconnected
          when owner.launchFailedWithoutResources =>
        (ConsoleStatus.failed, 'Shell could not be started.'),
      EnvironmentTerminalState.disconnected => (
        ConsoleStatus.disconnected,
        'Connection lost; termination is unconfirmed.',
      ),
      EnvironmentTerminalState.closed || EnvironmentTerminalState.disposed => (
        ConsoleStatus.completed,
        'Terminal closed.',
      ),
    };
    return ConsoleMetadata(
      title: policy.followTitle ? owner.title ?? fallbackTitle : fallbackTitle,
      status: status,
      description: description,
    );
  }

  ConsoleCloseAdvice get _closeAdvice {
    if (owner.launchFailedWithoutResources ||
        (owner.shellCompleted && owner.cleanupSucceeded)) {
      return const ConsoleCloseAdvice.noConfirmation();
    }
    if (owner.state == EnvironmentTerminalState.disconnected ||
        owner.cleanupError != null) {
      return ConsoleCloseAdvice.confirm(
        'Dismiss this terminal? Process termination is unconfirmed; '
        'dismissing the tab does not establish that the process stopped.',
      );
    }
    return ConsoleCloseAdvice.confirm(policy.liveCloseMessage);
  }

  void _changed() {
    if (_releasing != null || !_tab.isActive) return;
    _tab.updateMetadata(_metadata);
    // Only actual shell exit plus settled successful cleanup qualifies. A
    // nonzero exit code is still shell exit; stream EOF is not.
    if (policy.removeAfterExit &&
        owner.shellCompleted &&
        owner.cleanupSucceeded) {
      unawaited(_tab.requestRemoval());
    }
  }

  Future<ConsoleCleanupResult> release() => _releasing ??= _release();

  Future<ConsoleCleanupResult> _release() async {
    _detach?.call();
    _detach = null;
    final disconnected =
        owner.state == EnvironmentTerminalState.disconnected &&
        !owner.launchFailedWithoutResources;
    await coordinator.remove(owner);
    return ConsoleCleanupResult(
      warning: !owner.cleanupSucceeded || disconnected
          ? 'Terminal tab removed. Process termination could not be confirmed.'
          : null,
    );
  }
}
