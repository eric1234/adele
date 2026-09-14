/// The read-only primitive snapshot available to interpreted tool frontends.
/// Maps and all nested maps/lists are immutable. This is not execution state,
/// progress history, or approval authority.
abstract interface class ToolActivityInspectionSnapshot {
  Map<String, dynamic> get canonicalArguments;
  Map<String, dynamic> get hostData;

  /// Last non-progress ToolActivityKind.name, or 'prepared' initially.
  String get lifecycle;

  /// ToolOutcomeDisposition.name, absent until an outcome exists.
  String? get disposition;

  /// ToolFailureKind.name, absent when there is no failure kind.
  String? get failureKind;

  /// Outcome content, or the empty string before an outcome exists.
  String get modelContent;
}

ToolActivityInspectionSnapshot readToolActivitySnapshot() {
  throw UnsupportedError('Interpreted Tool activity inspection bridge only.');
}

/// Replaces this presentation's subscription. Notifications are read-only,
/// coalesced post-frame invalidations; read a fresh snapshot after notification.
void subscribeToolActivityChanges(void Function() callback) {
  throw UnsupportedError('Interpreted Tool activity inspection bridge only.');
}

void unsubscribeToolActivityChanges() {
  throw UnsupportedError('Interpreted Tool activity inspection bridge only.');
}
