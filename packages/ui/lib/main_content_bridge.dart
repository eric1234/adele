/// Interpreted-only requests for the exact contribution and Session attachment.
/// Snapshots contain only this contribution's local id, title, and canClose.
/// Retired access returns an empty snapshot; rejected requests return false.
List<Map<String, dynamic>> readMainContentPanes() =>
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
