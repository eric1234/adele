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

/// Copied arguments for the current finite operation. An active presentation or
/// an argument-free operation returns an empty map; retired access returns null.
/// Session/Environment identity is supplied only by readMainContentContext, and
/// the current pane by readMainContentPaneId, in main_content_bridge.dart.
Map<String, dynamic>? readContributionArguments() =>
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

/// Native two-choice confirmation for a finite operation. The requesting plugin
/// supplies exactly four nonempty strings: title, message, acceptLabel and
/// cancelLabel. It owns when to ask and the meaning of acceptance. False includes
/// dismissal, unavailable support, malformed requests and retired operation access.
Future<bool> confirmContribution(Map<String, dynamic> request) =>
    throw UnsupportedError('Prepared only.');
