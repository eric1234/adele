/// Interpreted-only Task Browser access, scoped to the presented Project.
library;

/// False once this exact presentation is retired, even if its view is retained.
/// Check before local mutations and after awaits; retained snapshots are display-only.
bool isTaskBrowserActive() =>
    throw UnsupportedError('Task Browser access requires a prepared frontend.');

/// Reads Project/Task/Session presentation data without creating execution owners.
///
/// Task rows include `sessionCount` and `executionCounts`, a map of integer
/// Session counts: `preparing`, `running`, `waiting`, `terminal`, `completed`,
/// `cancelled`, and `failed`. Terminal is the sum of the last three categories;
/// idle Sessions contribute only to sessionCount. These are latest retained
/// execution states, not cumulative Run totals or durable Task status.
///
/// Selected Task Session rows include `executionStatus`: `idle`, `preparing`,
/// `running`, `waitingForApproval`, `completed`, `cancelled`, or `failed`.
/// Status is independent of presentation `available`. Waiting grants no approval
/// authority; open the exact Session to use its host-owned approval surface.
Map<String, dynamic> readTaskBrowser() =>
    throw UnsupportedError('Task Browser access requires a prepared frontend.');

/// Actions always settle as [true, null] or [false, safeErrorString].
Future<List<dynamic>> selectTask(String? taskId) =>
    throw UnsupportedError('Task Browser access requires a prepared frontend.');

Future<List<dynamic>> createTask(String title) =>
    throw UnsupportedError('Task Browser access requires a prepared frontend.');

/// [optionHandle] is an opaque host-issued choice, not a strategy identity.
Future<List<dynamic>> createSession(String optionHandle) =>
    throw UnsupportedError('Task Browser access requires a prepared frontend.');

Future<List<dynamic>> openSession(String sessionId) =>
    throw UnsupportedError('Task Browser access requires a prepared frontend.');

/// Observes graph and generic execution-status changes, coalesced per frame.
/// Activity/output packets do not require a browser or workbench rebuild.
void subscribeTaskBrowser(void Function() listener) =>
    throw UnsupportedError('Task Browser access requires a prepared frontend.');

void unsubscribeTaskBrowser(void Function() listener) =>
    throw UnsupportedError('Task Browser access requires a prepared frontend.');
