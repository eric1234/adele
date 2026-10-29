/// Presentation-bound Session feedback. The host selects the canonical Session
/// and exact strategy; payloads and receipt identities never select a recipient.
/// Only opted-in mounted Main Content panes receive this bridge.
library;

/// Read-only availability: `available`, `canStart`, and an actionable `reason`.
/// Missing feedback support does not affect other presentation services.
Map<String, Object?> readSessionFeedbackAvailability() =>
    throw UnsupportedError('Interpreted host only.');

/// Delivers an already durably prepared canonical Session feedback payload.
/// Returns `accepted`, `unavailable`, or `uncertain`, never starts a Run.
Future<Map<String, Object?>> acceptSessionFeedback(String canonicalPayload) =>
    throw UnsupportedError('Interpreted host only.');

/// Explicit reconciliation, without replay. `absent` is not rollback; only an
/// explicit `retryAllowed` permits retrying this same immutable payload.
Future<Map<String, Object?>> lookupSessionFeedback(String canonicalPayload) =>
    throw UnsupportedError('Interpreted host only.');

/// Explicit ordinary Run admission after durable local acceptance finalization.
/// Callers persist scheduling intent first. Returns `scheduled`, `not_started`,
/// or `uncertain`. An uncertain acknowledgement must be reconciled, not replayed.
Future<Map<String, Object?>> startSessionFeedbackRun(
  String canonicalPayload,
  String occurrenceId,
  int schedulingAttempt,
) => throw UnsupportedError('Interpreted host only.');

/// Reconciles the accepted occurrence's retained/durable Run association. Never
/// starts execution or assumes that missing terminal history proves rollback.
Future<Map<String, Object?>> lookupSessionFeedbackRun(
  String canonicalPayload,
  String occurrenceId,
) => throw UnsupportedError('Interpreted host only.');
