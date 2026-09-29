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
