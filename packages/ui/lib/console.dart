import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter/widgets.dart';

import 'inspection_display.dart';

/// Independent contributions compose in one host-owned console, not a resolver.
final ExtensionPoint<ConsoleContribution> consoleContributions =
    ExtensionPoint<ConsoleContribution>('dev.adele.extension.consoles');

final class ConsoleContribution {
  ConsoleContribution({required List<ConsoleCreationAction> actions})
    : actions = List.unmodifiable(actions) {
    final ids = <String>{};
    for (final action in actions) {
      if (!ids.add(action.id)) {
        throw ArgumentError(
          'Console action IDs must be unique per contribution.',
        );
      }
    }
  }

  final List<ConsoleCreationAction> actions;
}

final class ConsoleCreationAction {
  ConsoleCreationAction({
    required this.id,
    required String label,
    required this.create,
  }) : label = _label(label, 80, 'New console') {
    if (id.isEmpty ||
        id.length > 128 ||
        !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]*$').hasMatch(id)) {
      throw ArgumentError(
        'Console action ID must be a bounded ASCII identifier.',
      );
    }
  }

  /// Local to the exact contribution registration, not a global action identity.
  final String id;
  final String label;
  final Future<void> Function(ConsoleCreationAccess) create;
}

abstract interface class ConsoleCreationAccess {
  /// The Session captured when the host admitted this action.
  Session get session;

  /// Active until this action settles or its exact host/owner retires.
  /// Navigation alone does not revoke an admitted, still-pending creation.
  bool get isActive;

  /// Transfers ownership to the host. Late content after retirement is released
  /// with a bounded wait and receives an inactive registration, never a new tab.
  /// Each content object may be transferred only once.
  ConsoleTabRegistration open(ConsoleContent content);
}

enum ConsoleStatus { idle, opening, running, completed, failed, disconnected }

final class ConsoleMetadata {
  ConsoleMetadata({
    required String title,
    String? description,
    this.status = ConsoleStatus.idle,
  }) : title = _label(title, 80, 'Console'),
       description = description == null ? null : _label(description, 240, '');

  final String title;
  final String? description;
  final ConsoleStatus status;
}

/// Content owns its evidence/resources independently of any mounted widget.
final class ConsoleContent {
  const ConsoleContent({
    required this.metadata,
    required this.isEligible,
    required this.createPresentation,
    this.closeAdvice,
    required this.release,
  });

  final ConsoleMetadata metadata;
  final bool Function(Session) isEligible;
  final Widget Function(ConsolePresentationAccess) createPresentation;

  /// Synchronous and advisory only. Missing, unknown, or failed advice requires
  /// generic confirmation. There is no veto and no asynchronous settlement hook.
  final ConsoleCloseAdvice? Function()? closeAdvice;
  final Future<ConsoleCleanupResult> Function() release;
}

abstract interface class ConsoleTabRegistration {
  bool get isActive;

  /// Updates only this content's metadata, including while its view is hidden.
  /// Calls after removal/retirement are inert.
  void updateMetadata(ConsoleMetadata metadata);

  /// Removes only this content, without user confirmation. Repeated requests and
  /// concurrent host cleanup join the same bounded release attempt.
  Future<void> requestRemoval();
}

abstract interface class ConsolePresentationAccess {
  /// Check at every view-originated effect, including after asynchronous work.
  /// Hide, selection/context change, unmount, or retirement permanently revokes
  /// this access; a new mount receives a different access object.
  bool get isActive;
}

final class ConsoleCloseAdvice {
  const ConsoleCloseAdvice.noConfirmation() : message = null;

  ConsoleCloseAdvice.confirm(String message)
    : message = _label(message, 240, 'Close this console?');

  final String? message;
}

final class ConsoleCleanupResult {
  ConsoleCleanupResult({String? warning})
    : warning = warning == null ? null : _label(warning, 240, '');

  /// Deliberately safe user-facing text, never a diagnostic exception dump.
  final String? warning;
}

String _label(String value, int limit, String fallback) {
  final bounded = compactDisplayText(value, maximumCharacters: limit);
  return bounded.trim().isEmpty ? fallback : bounded;
}
