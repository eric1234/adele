import 'package:flutter/widgets.dart';

/// Requests the single host-selected editor for this exact presentation.
/// The opaque handle cannot select a document or change host-selected read-only
/// policy. It grants no construction, controller, mutation, or disposal access.
String requestCodeEditor() => throw UnsupportedError(
  'Code editor access is available only to interpreted frontends.',
);

/// Builds the host-selected native editor. One presentation may display it at a
/// time. Native input follows normal component behavior; retiring a plugin handle
/// does not close the independently owned editor.
Widget buildCodeEditor(String handle) => throw UnsupportedError(
  'Code editor access is available only to interpreted frontends.',
);

/// Reads cheap immutable metadata, never document text or selection offsets.
/// Fields are `ready`, `readOnly`, `revision`, and `language`. Revision counts
/// component notifications, including possible selection/layout changes. It is
/// not a content version, dirty flag, or filesystem revision.
Map<String, dynamic> readCodeEditorState(String handle) =>
    throw UnsupportedError(
      'Code editor access is available only to interpreted frontends.',
    );

/// Deliberately reads `text` and the current notification `revision`. This is not
/// a save transaction or a promise about uncommitted composition. No text is sent
/// automatically with notifications. Retired handles fail closed.
Map<String, dynamic> snapshotCodeEditor(String handle) =>
    throw UnsupportedError(
      'Code editor access is available only to interpreted frontends.',
    );

/// Observes coalesced component invalidation with no text payload. Retain the same
/// listener object for unsubscription. Duplicate subscription is idempotent.
void subscribeCodeEditor(String handle, void Function() listener) =>
    throw UnsupportedError(
      'Code editor access is available only to interpreted frontends.',
    );

/// Removes the exact listener; harmless after presentation retirement.
void unsubscribeCodeEditor(String handle, void Function() listener) =>
    throw UnsupportedError(
      'Code editor access is available only to interpreted frontends.',
    );
