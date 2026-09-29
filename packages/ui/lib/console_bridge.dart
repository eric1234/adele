/// Interpreted-only console admission. The host captures the exact declaring
/// installation and canonical Session; IDs and data do not confer authority.
Future<List<dynamic>> openPreparedConsole(
  String extensionId,
  String key,
  String title,
  Map<String, dynamic> data,
) => throw UnsupportedError('Console bridge requires a prepared presentation.');

Map<String, dynamic> readConsoleContentData() =>
    throw UnsupportedError('Console bridge requires a prepared content view.');

Map<String, dynamic> readConsoleContentState() =>
    throw UnsupportedError('Console bridge requires a prepared content view.');

/// Saves bounded logical follow/history state, never transcript or view objects.
/// Returns false after the view is revoked or if the state exceeds host bounds.
bool writeConsoleContentState(Map<String, dynamic> state) =>
    throw UnsupportedError('Console bridge requires a prepared content view.');

/// Captures the current selection grant, or zero while interaction is inactive.
/// A positive epoch belongs to this resident presentation and never becomes
/// active again after selection changes, even when the same tab is reselected.
int readConsoleInteraction() =>
    throw UnsupportedError('Console bridge requires a prepared content view.');

/// Revalidate an epoch captured by the originating callback, including after
/// awaits. Reading a fresh epoch cannot authorize work from an older callback.
bool isConsoleInteractionActive(int epoch) =>
    throw UnsupportedError('Console bridge requires a prepared content view.');

/// Coalesced, deferred selection notifications. Resident reads and observation
/// remain usable while interaction is inactive. Retain the callback to remove it.
void subscribeConsoleInteraction(void Function() listener) =>
    throw UnsupportedError('Console bridge requires a prepared content view.');

void unsubscribeConsoleInteraction(void Function() listener) =>
    throw UnsupportedError('Console bridge requires a prepared content view.');
