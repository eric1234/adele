import 'dart:async';

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter/widgets.dart';

/// Namespaced semantic content identity, independent of a presenter registration.
final class SessionContentKind {
  factory SessionContentKind(String value) {
    if (value.length > maxLength) {
      throw const FormatException(
        'Session content kind must not exceed 128 ASCII characters.',
      );
    }
    try {
      validateAdelePublicId(value, label: 'Session content kind');
    } on FormatException {
      throw const FormatException(
        'Session content kind must be a lowercase reverse-domain ASCII identifier.',
      );
    }
    return SessionContentKind._(value);
  }

  const SessionContentKind._(this.value);

  static const maxLength = 128;
  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionContentKind && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Opaque occurrence reference within a Session and content kind, not authority.
/// Starts with an ASCII letter or digit; remaining characters may also be ._:/-.
final class SessionContentOccurrenceId {
  factory SessionContentOccurrenceId(String value) {
    if (value.isEmpty || value.length > maxLength) {
      throw const FormatException(
        'Session content occurrence ID must contain 1..256 ASCII characters.',
      );
    }
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]*$').hasMatch(value)) {
      throw const FormatException(
        'Session content occurrence ID must be a safe ASCII identifier.',
      );
    }
    return SessionContentOccurrenceId._(value);
  }

  const SessionContentOccurrenceId._(this.value);

  static const maxLength = 256;
  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionContentOccurrenceId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Read-only facts and presentation lifetime for one captured content occurrence.
/// The Session, kind, and occurrence identities remain fixed, including after
/// retirement. Presentation may listen, but neither disposes nor revokes this
/// host-owned source and gains no execution, approval, or backend authority.
abstract interface class SessionContentInspectionContext implements Listenable {
  Session get session;
  SessionContentKind get kind;
  SessionContentOccurrenceId get occurrenceId;

  /// Becomes false permanently when this presentation's captured lifetime ends.
  /// The host notifies listeners synchronously on revocation, before unmount.
  bool get isActive;
}

/// Exactly one contribution may inspect an exact semantic content kind.
final ExtensionPoint<SessionContentInspectionContribution>
sessionContentInspectionContributions =
    ExtensionPoint<SessionContentInspectionContribution>(
      'dev.adele.extension.session-content-inspections',
    );

final class SessionContentInspectionContribution {
  const SessionContentInspectionContribution({
    required this.kind,
    required this.createPresentation,
  });

  final SessionContentKind kind;

  /// Creates read-only presentation for the captured occurrence. Hosts retain and
  /// validate the exact registration, including after asynchronous completion.
  /// Context revocation may precede widget unmount or factory completion.
  final FutureOr<Widget> Function(SessionContentInspectionContext)
  createPresentation;
}

final class SessionContentInspectionResolver {
  const SessionContentInspectionResolver(this._registry);

  final ExtensionRegistry _registry;

  ExtensionBinding<SessionContentInspectionContribution> resolve(
    SessionContentKind kind,
  ) {
    final matches = [
      for (final binding in _registry.discover(
        sessionContentInspectionContributions,
      ))
        if (binding.value.kind == kind) binding,
    ];
    if (matches.isEmpty) throw SessionContentInspectionUnavailable(kind);
    if (matches.length > 1) {
      throw AmbiguousSessionContentInspection(
        kind,
        matches.map((binding) => binding.id),
      );
    }
    return matches.single;
  }
}

final class SessionContentInspectionUnavailable implements Exception {
  const SessionContentInspectionUnavailable(this.kind);

  final SessionContentKind kind;

  @override
  String toString() =>
      'SessionContentInspectionUnavailable: Content kind $kind has no inspection.';
}

final class AmbiguousSessionContentInspection implements Exception {
  AmbiguousSessionContentInspection(
    this.kind,
    Iterable<ExtensionId> extensionIds,
  ) : extensionIds = List<ExtensionId>.unmodifiable(
        List<ExtensionId>.of(extensionIds)
          ..sort((a, b) => a.value.compareTo(b.value)),
      );

  final SessionContentKind kind;
  final List<ExtensionId> extensionIds;

  @override
  String toString() =>
      'AmbiguousSessionContentInspection: Content kind $kind has inspections '
      'from ${extensionIds.join(', ')}.';
}
