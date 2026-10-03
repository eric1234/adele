/// Prepared Main Content's opt-in, current-window retained data. Values are copied
/// primitive maps, never widgets, callbacks, access objects or native controllers.
/// Keys and their meaning belong to the exact contribution, not the host.
List<String> readContributionKeys() => throw UnsupportedError('Prepared only.');
Map<String, dynamic> readContributionData(String key) =>
    throw UnsupportedError('Prepared only.');
bool writeContributionData(String key, Map<String, dynamic> data) =>
    throw UnsupportedError('Prepared only.');
bool removeContributionData(String key) =>
    throw UnsupportedError('Prepared only.');
String allocateContributionId() => throw UnsupportedError('Prepared only.');

/// Captured environmentKey (identity data, not authority), paneId and arguments.
/// Exit operations have no Environment. Presentation handles are freshly issued
/// on every attachment; admitted finite operations retain their original owner.
Map<String, dynamic> readContributionContext() =>
    throw UnsupportedError('Prepared only.');

/// Invoke only an operation named in this contribution's prepared descriptor.
/// Admission captures the Environment before asynchronous work. Completion may
/// update retained data after departure, but never revives a departed callback.
Future<Map<String, dynamic>> invokeContributionOperation(
  String operation,
  Map<String, dynamic> arguments,
) => throw UnsupportedError('Prepared only.');

/// Notifications invalidate copied data, not native text snapshots.
void subscribeContribution(void Function() listener) =>
    throw UnsupportedError('Prepared only.');
void unsubscribeContribution(void Function() listener) =>
    throw UnsupportedError('Prepared only.');

/// Supplied-text construction grants no filesystem authority. The native owner
/// survives presentation departure. Existing IDs are rejected without replacement.
Future<bool> createContributionCodeEditor(
  String id,
  String text,
  String language,
) => throw UnsupportedError('Prepared only.');
Map<String, dynamic> snapshotContributionCodeEditor(String id) =>
    throw UnsupportedError('Prepared only.');
Map<String, dynamic> readContributionCodeEditorState(String id) =>
    throw UnsupportedError('Prepared only.');
bool releaseContributionCodeEditor(String id) =>
    throw UnsupportedError('Prepared only.');

/// Only finite operations receive file access to their host-captured Environment.
/// Success: {ok: true, path, text, sizeBytes, revision} for read; replacement
/// returns {ok: true, revision}. Failure: {ok: false, failure:
/// {code, message, details}}. Complete files only; there is no preview/truncation.
Future<Map<String, dynamic>> readEnvironmentTextFile(String path) =>
    throw UnsupportedError('Prepared only.');
Future<Map<String, dynamic>> replaceEnvironmentTextFile(
  String path,
  String text,
  String expectedRevision,
) => throw UnsupportedError('Prepared only.');

/// Generic host modal support; plugin supplies the document-specific explanation.
/// False includes cancellation or unavailable presentation support.
Future<bool> confirmContributionDiscard(String message) =>
    throw UnsupportedError('Prepared only.');
