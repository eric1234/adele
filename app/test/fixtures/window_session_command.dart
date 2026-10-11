import 'dart:async';

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';

/// A native semantic Command with no presentation or execution authority.
final class WindowSessionCommandFixture {
  WindowSessionCommandFixture({
    required this.context,
    required ExtensionRegistry registry,
    this.gate,
  }) {
    initialSnapshot = context.snapshot;
    contribution = CommandContribution(
      id: commandId,
      label: label,
      availability: () {
        if (!context.isActive) return CommandAvailability.disabled;
        return context.snapshot.session == null
            ? CommandAvailability.hidden
            : CommandAvailability.enabled;
      },
      invoke: () async {
        final capturedSnapshot = context.snapshot;
        captured.add(capturedSnapshot);
        await gate?.future;
        completed.add(capturedSnapshot);
      },
    );
    registration = registry.register(
      point: commandContributions,
      id: ExtensionId('dev.adele.test.window-session-command'),
      value: contribution,
    );
    command = CommandResolver(registry).resolve(commandId);
    final detach = context.observe(changes.add);
    command.binding.onRetire(detach);
  }

  static final commandId = CommandId('dev.adele.test.capture-window-session');
  static const label = 'Capture Window Session';

  final WindowSessionContext context;
  final Completer<void>? gate;
  late final WindowSessionSnapshot initialSnapshot;
  late final CommandContribution contribution;
  late final ExtensionRegistration registration;
  late final ResolvedCommand command;
  final changes = <WindowSessionSnapshot>[];
  final captured = <WindowSessionSnapshot>[];
  final completed = <WindowSessionSnapshot>[];

  Future<void> close() => registration.close();
}
