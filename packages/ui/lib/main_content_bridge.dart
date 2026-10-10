/// Interpreted-only requests for the exact contribution and Session attachment.
/// Snapshots contain only this contribution's local id, title, and canClose.
/// Retired access returns an empty snapshot; rejected requests return false.
List<Map<String, dynamic>> readMainContentPanes() =>
    throw UnsupportedError('Main Content requires a prepared contribution.');

/// Immutable captured context: sessionId, strategyId, taskId and environmentKey.
/// Environment identity comes from the canonical Session's retained association,
/// independently of file permission or provider availability. No materialization
/// is performed. Available in views, initialization and finite operations;
/// Session-less exit operations and retired access return an empty map.
/// Identities are data, not authority to select a Session or Environment.
Map<String, dynamic> readMainContentContext() =>
    throw UnsupportedError('Main Content requires a prepared contribution.');

/// The current pane's local ID, or an empty string during initialization or after
/// retirement. IDs are data, not authority to access another contribution.
String readMainContentPaneId() =>
    throw UnsupportedError('Main Content requires a prepared contribution.');

/// Rejects an existing local ID without replacing or focusing its pane, or
/// allocating another pane's resources. Use focusMainContentPane to reveal it.
/// canClose asks the host to expose a close action that removes this pane.
bool openMainContentPane(String id, String title, bool canClose) =>
    throw UnsupportedError('Main Content requires a prepared contribution.');

bool setMainContentPaneTitle(String id, String title) =>
    throw UnsupportedError('Main Content requires a prepared contribution.');

/// Reorders this contribution's panes using an exact permutation of their IDs.
bool setMainContentPaneOrder(List<String> ids) =>
    throw UnsupportedError('Main Content requires a prepared contribution.');

bool removeMainContentPane(String id) =>
    throw UnsupportedError('Main Content requires a prepared contribution.');

bool focusMainContentPane(String id, bool keyboardFocus) =>
    throw UnsupportedError('Main Content requires a prepared contribution.');

/// Side-effect-free source-display discovery for this mounted pane. Returns
/// available, unavailable (no provider/current attachment), ambiguous, denied
/// (no consumer declaration), or retired. This does not reserve a provider.
String sourceDisplayAvailability() =>
    throw UnsupportedError('Main Content requires a prepared contribution.');

/// Requests source display through one exact public extension registration.
/// Only mounted panes declaring canRequestSourceDisplay receive access. The host
/// captures the canonical Session; the caller supplies only the unchanged
/// Environment-relative path, never Session or Environment authority.
///
/// Returns a map with status: success, unavailable, ambiguous, failed, denied, or
/// retired. Native diagnostics and provider payloads are not exposed. Departure
/// fences publication, not an already-admitted finite provider operation's effects.
Future<Map<String, dynamic>> displaySourceFile(String relativePath) =>
    throw UnsupportedError('Main Content requires a prepared contribution.');
