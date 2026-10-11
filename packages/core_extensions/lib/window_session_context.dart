import 'package:adele_product/adele_product.dart';

/// One immutable selection epoch, not execution state or an authority grant.
final class WindowSessionSnapshot {
  const WindowSessionSnapshot({required this.session, required this.revision});

  /// The canonical product object presented by this window, or no Session.
  final Session? session;

  /// Starts at zero with no Session and increases on each committed change.
  /// Leaving and returning to the same Session establishes a fresh revision.
  final int revision;
}

/// Read-only, window-scoped Session selection, independent of any UI contribution.
/// A headless runtime has no implicit selected Session. Observation grants no
/// filesystem, storage, Environment, execution, or approval authority.
abstract interface class WindowSessionContext {
  /// False after the owning window ends access. Never becomes true again.
  bool get isActive;

  /// Synchronously reads the current selection, including for late consumers.
  /// Throws [StateError] after access ends. Previously captured snapshots remain
  /// immutable facts; they are not live presentation or executable grants.
  WindowSessionSnapshot get snapshot;

  /// Observes committed changes synchronously, in revision order. Does not replay
  /// the current snapshot; read [snapshot] when attaching. Navigation preparation,
  /// rejected departure, Run activity, and unchanged selection do not notify.
  ///
  /// Returns an idempotent detach callback. Detaching suppresses later callbacks,
  /// including one not yet delivered in an ongoing notification. Window shutdown
  /// invalidates all observers without publishing a synthetic navigation event.
  /// New subscriptions after shutdown throw [StateError].
  ///
  /// Listener failures are reported to the listener's Zone, never rolled back or
  /// propagated to the publisher or other observers. Listeners cannot publish;
  /// host publication rejects reentrant selection changes during notification.
  void Function() observe(void Function(WindowSessionSnapshot) listener);
}
