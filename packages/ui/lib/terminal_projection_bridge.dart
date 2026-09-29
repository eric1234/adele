import 'package:flutter/widgets.dart';

/// Creates this presentation's independent, revocable, read-only projection.
/// Repeated requests return the same handle and must use the same [rows].
/// Geometry is fixed at 80 columns and 6 (preview) or 20 (console) rows, with
/// 200 retained lines including the viewport. Neither layout nor output can
/// resize it. Pipe LF starts the next line at column zero, unlike a PTY feed.
/// CSI REP renders up to 1024 repetitions exactly. A larger count fails and
/// retires this projection rather than silently truncating captured output.
String requestTerminalProjection(int rows) => throw UnsupportedError(
  'Terminal projection access is available only to interpreted frontends.',
);

/// Builds the single native view. Local scroll, selection and explicit copy are
/// supported; no input, paste, response, resize, signal or ambient action is
/// authorized. No terminal-library types cross this boundary.
Widget buildTerminalProjection(String handle) => throw UnsupportedError(
  'Terminal projection access is available only to interpreted frontends.',
);

/// Parses an ordered prefix and returns its accepted UTF-16 code-unit count.
/// At most 1024 units are accepted per call. Feeding stops once downward rendered
/// row advances reach min([lineBudget], rows), checked between atomic parser
/// operations. LF/soft-wrap stop exactly; cursor/scroll controls may cross the
/// row budget atomically. A surrogate pair is never split by this bound. A
/// nonpositive budget or frozen projection accepts zero. No remainder is queued.
/// A caller-split high surrogate is retained as at most one unit of parser state
/// until the next feed; reset discards it along with partial escape sequences.
/// The reader owns its history and cursor, advances only by the returned count,
/// and must yield to the event loop between bounded calls during prefix replay.
/// Returns -1 on unsupported amplification: no prefix of that call is
/// acknowledged, the presentation fails safely, and its handle is retired.
/// Do not advance the source cursor or continue replay after a negative result.
int feedTerminalProjection(String handle, String text, int lineBudget) =>
    throw UnsupportedError(
      'Terminal projection access is available only to interpreted frontends.',
    );

/// Yields bounded replay work to native input/layout. Returns false if this exact
/// presentation was revoked before resumption; does not fetch or queue output.
Future<bool> yieldTerminalProjection(String handle) => throw UnsupportedError(
  'Terminal projection access is available only to interpreted frontends.',
);

/// Clears parser, screen, selection and progress, and enables feeding/follow.
/// History readers replay from the beginning to restore parser state; this is
/// not permission to fetch, execute, or continue any backend operation.
void resetTerminalProjection(String handle) => throw UnsupportedError(
  'Terminal projection access is available only to interpreted frontends.',
);

/// Immutable snapshot: following (bool), columns/rows/maxLines,
/// maxFeedCodeUnits, historyWindowCodeUnits, acceptedCodeUnits, lineAdvances,
/// firstRetainedLine, retainedLines (int), scrollOffset/maxScrollOffset (double).
/// Progress starts at zero on reset. Row advances count downward cursor movement
/// and scrollback eviction, not semantic source lines. Source offsets remain the
/// authoritative history cursor, including carriage-return/ANSI rewrites.
/// historyWindowCodeUnits is a conservative plain-output source window budget
/// (maxLines - rows - 2), including worst-case one LF per code unit; it does not
/// promise preservation against terminal commands that erase or rewrite output.
Map<String, dynamic> readTerminalProjection(String handle) =>
    throw UnsupportedError(
      'Terminal projection access is available only to interpreted frontends.',
    );

/// False freezes the feed as well as follow. User scroll-away or selection freezes it
/// synchronously, so a queued plugin feed cannot evict the inspected region.
/// True resumes feed and scrolls to the current bottom; the reader must replay
/// missing history before treating that position as the current output tail.
void setTerminalProjectionFollow(String handle, bool following) =>
    throw UnsupportedError(
      'Terminal projection access is available only to interpreted frontends.',
    );

/// Scrolls within the local retained buffer in logical pixels and freezes feed.
void scrollTerminalProjection(String handle, double offset) =>
    throw UnsupportedError(
      'Terminal projection access is available only to interpreted frontends.',
    );

/// Coalesced invalidations, not transcript events. Retain the exact callback for
/// unsubscription. Queued callbacks are fenced on retirement; no initial replay.
void subscribeTerminalProjection(String handle, void Function() listener) =>
    throw UnsupportedError(
      'Terminal projection access is available only to interpreted frontends.',
    );

void unsubscribeTerminalProjection(String handle, void Function() listener) =>
    throw UnsupportedError(
      'Terminal projection access is available only to interpreted frontends.',
    );
