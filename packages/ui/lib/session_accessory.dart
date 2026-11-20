import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter/widgets.dart';

/// Meaning, not physical placement. Only an explicitly mounted location renders.
enum SessionAccessoryLocation {
  executionConfiguration('execution-configuration');

  const SessionAccessoryLocation(this.id);
  final String id;
}

/// Independent controls, ordered within a location by order then ExtensionId.
final sessionAccessoryContributions =
    ExtensionPoint<SessionAccessoryContribution>(
      'dev.adele.extension.session-accessories',
    );

final class SessionAccessoryContribution {
  const SessionAccessoryContribution({
    required this.location,
    required this.order,
    required this.createPresentation,
    this.detach,
  });

  final SessionAccessoryLocation location;
  final int order;

  /// Called once per mount and exact registration, not on ordinary rebuilds.
  final Widget Function(SessionAccessoryAccess access) createPresentation;

  /// Called once after revocation, including when the factory throws. Mounted
  /// Flutter resources should still be disposed by their owning widget State.
  final void Function(SessionAccessoryAccess access)? detach;
}

abstract interface class SessionAccessoryAccess {
  /// Never retargeted. Throws StateError after this presentation is retired.
  Session get session;

  /// Check again before publishing an asynchronous result. Revocation does not
  /// roll back an already admitted external effect.
  bool get isActive;
}
