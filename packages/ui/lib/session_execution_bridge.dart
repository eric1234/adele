import 'package:flutter/widgets.dart';

/// These functions are supplied by the host to one interpreted Session view.
/// Identifiers in snapshots are data; only emitted opaque handles select activity.
String currentSessionId() => throw UnsupportedError('Interpreted host only.');

/// `sessionStateRevision` changes when strategy materialization or terminal
/// settlement can change canonical Session state. Capture it before hydration
/// and compare after subscribing/reading; ordinary activity changes do not bump it.
Map<String, Object?> readSessionExecution() =>
    throw UnsupportedError('Interpreted host only.');

/// Resolves when a fresh Run is scheduled, not when execution completes.
Future<String> startSessionRun() =>
    throw UnsupportedError('Interpreted host only.');

/// Opens accepted preparing/live/waiting or retained terminal activity belonging
/// to this canonical Session, or returns null when unavailable. Preparation and
/// startup failure may have an empty evidence list. Fresh presentations receive fresh
/// opaque handles, never revived old handles or execution/approval authority.
String? openSessionRunActivity(String runId) =>
    throw UnsupportedError('Interpreted host only.');

/// Settles an already-started Future as `[true, value]` or `[false, null]`.
/// Native rejection does not reliably unwind interpreted try/await. Success
/// values stay in their originating runtime; exceptions and stacks do not cross.
Future<List<dynamic>> settleSessionOperation(Future<dynamic> operation) =>
    throw UnsupportedError('Interpreted host only.');

/// Retain the listener object and pass that same object to unsubscribe.
void subscribeSessionExecution(void Function() listener) =>
    throw UnsupportedError('Interpreted host only.');

void unsubscribeSessionExecution(void Function() listener) =>
    throw UnsupportedError('Interpreted host only.');

/// Immutable primitive evidence. Tool outputs retain proposal `arguments`, an
/// optional `rejection`, and optional prepared `tool` lifecycle/changes/outcome.
/// All remain attached to the original output handle; identities grant no action
/// or approval authority. Raw provider-native replay data is not exposed.
Map<String, Object?> readSessionRunActivity(String runHandle) =>
    throw UnsupportedError('Interpreted host only.');

bool inspectSessionActivity(String activityHandle) =>
    throw UnsupportedError('Interpreted host only.');

Widget buildSessionActivity(String activityHandle) =>
    throw UnsupportedError('Interpreted host only.');

/// Host-owned status and approval controls for this exact presentation's Session.
/// The plugin chooses placement, not decision permissions or approval identity.
Widget buildSessionExecutionStatus() =>
    throw UnsupportedError('Interpreted host only.');
