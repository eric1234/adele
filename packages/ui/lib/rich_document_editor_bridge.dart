import 'package:flutter/widgets.dart';

/// Creates an in-memory editor from plugin-supplied Markdown in this exact
/// presentation. At most 16 unreleased editors may exist. Creation may follow
/// asynchronous hydration, but never presentation retirement. The opaque handle
/// supplies no document lookup, persistence, controller, or mode-changing API.
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

/// Copies `markdown`, `revision`, `readOnly`, and nullable `unsupportedReason`.
/// Revision counts document transaction invalidations, not saves or selection.
/// It is not a persisted-content version or dirty flag. Notifications carry no content;
/// this explicit snapshot is not a save transaction or a composition guarantee.
/// If edited content cannot be represented safely, `markdown` is null and
/// `error` is `unsupported_serialization`. No old or degraded Markdown is returned.
Map<String, dynamic> snapshotRichDocumentEditor(String handle) =>
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
