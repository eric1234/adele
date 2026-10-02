import 'package:flutter/widgets.dart';

/// Requests the single host-selected editor for this exact presentation.
/// The opaque handle cannot select a document or change host-selected read-only
/// policy. It grants no construction, controller, mutation, or disposal access.
String requestCodeEditor() => throw UnsupportedError(
  'Code editor access is available only to interpreted frontends.',
);

/// Builds a native editor body. Cached widgets remain revocable, including while
/// retained for exit. Only one mounted editor may attach to a buffer at a time.
Widget buildCodeEditor(String handle) => throw UnsupportedError(
  'Code editor access is available only to interpreted frontends.',
);

/// Reads cheap immutable metadata, never document text or selection offsets.
/// Fields are `ready`, `readOnly`, `version`, `language`, `focused`,
/// `horizontalOffset`, and `verticalOffset`. Before native initialization,
/// `ready` is false and `version` is zero.
/// Native input owns editing, selection, clipboard actions, and undo; reading
/// metadata grants none of those operations.
Map<String, dynamic> readCodeEditorState(String handle) =>
    throw UnsupportedError(
      'Code editor access is available only to interpreted frontends.',
    );

/// Deliberately copies immutable text, version, and selection in one snapshot.
/// Fields are `text` (String), `version` (int), `selectionBase` (int),
/// `selectionExtent` (int), and `selectionUnit` (`utf16`). Selection offsets use
/// UTF-16 code units in that same captured text, not a later document version.
/// This bounded synchronous read requires initialized native state. It is not a
/// per-keystroke transport and queues no snapshot futures. Retired access fails;
/// fresh presentations require fresh handles.
Map<String, dynamic> snapshotCodeEditor(String handle) =>
    throw UnsupportedError(
      'Code editor access is available only to interpreted frontends.',
    );

/// Observes coalesced content/initial-readiness invalidation with no text payload.
/// Selection, scrolling and painting alone do not advance content version. Retain the same
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
