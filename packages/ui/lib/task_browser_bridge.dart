/// Interpreted-only Task Browser access, scoped to the presented Project.
library;

/// False once this exact presentation is retired, even if its view is retained.
/// Check before local mutations and after awaits; retained snapshots are display-only.
bool isTaskBrowserActive() =>
    throw UnsupportedError('Task Browser access requires a prepared frontend.');

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

void subscribeTaskBrowser(void Function() listener) =>
    throw UnsupportedError('Task Browser access requires a prepared frontend.');

void unsubscribeTaskBrowser(void Function() listener) =>
    throw UnsupportedError('Task Browser access requires a prepared frontend.');
