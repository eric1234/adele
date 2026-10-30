import 'package:flutter/widgets.dart';

/// Creates an in-memory editor from plugin-supplied Markdown in this exact
/// presentation. At most 16 unreleased editors may exist. Creation may follow
/// asynchronous hydration, but never presentation retirement. The opaque handle
/// supplies no document lookup, persistence, or controller API.
/// Unsupported imports preserve their original source read-only with a reason.
String createRichDocumentEditor(String markdown, bool readOnly) =>
    throw UnsupportedError(
      'Rich document editor access is available only to interpreted frontends.',
    );

/// Builds one native view. Rebuilding or temporarily unmounting it preserves
/// content and undo until explicit release or presentation retirement.
Widget buildRichDocumentEditor(String handle) => throw UnsupportedError(
  'Rich document editor access is available only to interpreted frontends.',
);

/// Copies `markdown`, `revision`, `readOnly`, `editingEnabled`, `isBlank`, and
/// nullable `unsupportedReason`. `isBlank` checks model text, not Markdown syntax;
/// empty headings/lists/code are blank. Unsupported imports use raw source text.
/// Revision counts document transaction invalidations, not saves or selection.
/// It is not a persisted-content version or dirty flag. Notifications carry no content;
/// this explicit snapshot is not a save transaction.
/// During native composition or a settling input delta, `markdown` and `isBlank`
/// are null and `error` is `composition_pending`. Finish composition and retry
/// after invalidation before saving, sending, or leaving. Blur, disabling, and
/// unmounting do not establish a commit. Composition completion notifies even
/// without a document revision change.
/// If edited content cannot be represented safely, `markdown` is null and
/// `error` is `unsupported_serialization`. No old or degraded Markdown is returned.
Map<String, dynamic> snapshotRichDocumentEditor(String handle) =>
    throw UnsupportedError(
      'Rich document editor access is available only to interpreted frontends.',
    );

/// Temporarily enables/disables editing without replacing content or undo.
/// Disabling synchronously closes already-focused input. Enabling never upgrades
/// construction-time read-only or unsupported imports, nor revives a retired or
/// released handle. Invalid handles fail. Snapshot before disabling to finalize;
/// disabling does not commit pending composition. Re-enabling does not focus.
void setRichDocumentEditorEditingEnabled(String handle, bool enabled) =>
    throw UnsupportedError(
      'Rich document editor access is available only to interpreted frontends.',
    );

/// Observes coalesced invalidation without content. Duplicate subscription is
/// idempotent; retain the exact listener object for unsubscription.
void subscribeRichDocumentEditor(String handle, void Function() listener) =>
    throw UnsupportedError(
      'Rich document editor access is available only to interpreted frontends.',
    );

/// Removes the exact listener. Harmless after the whole presentation retires;
/// foreign, unknown, or released handles fail while the presentation is active.
void unsubscribeRichDocumentEditor(String handle, void Function() listener) =>
    throw UnsupportedError(
      'Rich document editor access is available only to interpreted frontends.',
    );

/// Permanently revokes the handle, closes native input, and disposes its owner.
/// Presentation retirement does this for every remaining editor, even during
/// exit retention. Harmless after the whole presentation retires.
void releaseRichDocumentEditor(String handle) => throw UnsupportedError(
  'Rich document editor access is available only to interpreted frontends.',
);
