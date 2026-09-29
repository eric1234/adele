import 'dart:collection';

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter/widgets.dart';

import 'inspection_display.dart';

/// Independent contributions compose in one host-owned console, not a resolver.
final ExtensionPoint<ConsoleContribution> consoleContributions =
    ExtensionPoint<ConsoleContribution>('dev.adele.extension.consoles');

final class ConsoleContribution {
  ConsoleContribution({
    required List<ConsoleCreationAction> actions,
    this.openPrepared,
  }) : actions = List.unmodifiable(actions) {
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

  /// A declared, host-owned factory, not a callback retained from the requesting
  /// presentation. The host deduplicates by exact owner, Session, and key.
  final Future<void> Function(ConsoleCreationAccess, ConsoleContentDescriptor)?
  openPrepared;
}

/// Opaque plugin data copied out of the requesting presentation. It confers no
/// backend, Session, or resource authority. Equal keys focus existing content;
/// subsequent requests do not replace its data or logical state.
final class ConsoleContentDescriptor {
  ConsoleContentDescriptor({
    required this.key,
    required this.metadata,
    required Map<String, Object?> data,
  }) : data = copyConsoleContentData(data) {
    if (key.trim().isEmpty ||
        key.length > 256 ||
        key.contains(RegExp(r'[\x00-\x1f\x7f-\x9f]'))) {
      throw const FormatException('Invalid console content key.');
    }
  }

  final String key;
  final ConsoleMetadata metadata;
  final Map<String, Object?> data;
}

/// Shared bounds for descriptors and retained logical view state. Neither may
/// carry a transcript, executable object, or evaluator lifetime.
Map<String, Object?> copyConsoleContentData(Map<String, Object?> data) {
  final visiting = HashSet<Object>.identity();
  var nodes = 256;
  var text = 8192;
  Object? copy(Object? value, int depth) {
    if (--nodes < 0 || depth > 16) {
      throw const FormatException('Console content data is too large.');
    }
    if (value is String) {
      text -= value.length;
      if (text < 0) {
        throw const FormatException('Console content data is too large.');
      }
      return value;
    }
    if (value == null || value is bool || value is int) return value;
    if (value is double && value.isFinite) return value;
    if (value is! List && value is! Map<String, Object?>) {
      throw const FormatException('Console content data must be structured.');
    }
    if (!visiting.add(value)) {
      throw const FormatException('Console content data must not be cyclic.');
    }
    try {
      if (value is List) {
        return List<Object?>.unmodifiable([
          for (final item in value) copy(item, depth + 1),
        ]);
      }
      return Map<String, Object?>.unmodifiable({
        for (final entry in (value as Map<String, Object?>).entries)
          copy(entry.key, depth + 1) as String: copy(entry.value, depth + 1),
      });
    } finally {
      visiting.remove(value);
    }
  }

  return copy(data, 0) as Map<String, Object?>;
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
    this.keepAlive = false,
    this.closeAdvice,
    required this.release,
  });

  final ConsoleMetadata metadata;
  final bool Function(Session) isEligible;
  final Widget Function(ConsolePresentationAccess) createPresentation;

  /// Opts into the host's bounded, current-Session presentation working set.
  /// This retains a visited presentation, not its foreground interaction grant.
  /// Default content is disposed on deselection; resources have their own owner.
  final bool keepAlive;

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
  /// Resident observation/projection lifetime. Eviction, collapse, Session
  /// departure, unmount, or retirement permanently ends this exact access.
  bool get isActive;

  /// Synchronous notification when interaction or resident authority changes.
  Listenable get changes;

  /// The current selected-visible activation, or null while dormant. Capture it
  /// when building a user callback and recheck it after asynchronous work. A
  /// later selection cannot revive a previously captured activation.
  ConsoleInteractionAccess? get interaction;
}

abstract interface class ConsoleInteractionAccess {
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
