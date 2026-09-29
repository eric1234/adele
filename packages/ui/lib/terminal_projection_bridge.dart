import 'package:flutter/widgets.dart';

/// Creates this presentation's independent, revocable, read-only projection.
/// Repeated requests must use the same [rows] and [alwaysFollow] policy.
/// The plugin explicitly selects [alwaysFollow]; it is never inferred from rows.
/// When true, local selection cannot freeze feeding and vertical user scrolling
/// passes to the surrounding view. Selection and explicit copy remain local.
/// Geometry is fixed at 80 columns and 6 or 20 rows, with
/// 200 retained lines including the viewport. Neither layout nor output can
/// resize it. Pipe LF starts the next line at column zero, unlike a PTY feed.
/// CSI REP renders up to 1024 repetitions exactly. A larger count fails and
/// retires this projection rather than silently truncating captured output.
String requestTerminalProjection(int rows, bool alwaysFollow) =>
    throw UnsupportedError(
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
/// Preserves the configured resumeAtEnd policy for bounded history replay.
/// History readers replay from the beginning to restore parser state; this is
/// not permission to fetch, execute, or continue any backend operation.
void resetTerminalProjection(String handle) => throw UnsupportedError(
  'Terminal projection access is available only to interpreted frontends.',
);

/// Immutable snapshot: following/alwaysFollow/resumeAtEnd (bool), columns/rows/maxLines,
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

/// For a non-always-follow projection, false freezes feed as well as follow.
/// User scroll-away or selection freezes synchronously before queued feeds.
/// [resumeAtEnd] allows actual user scrolling back to the rendered cursor end
/// to resume, but only without active selection. Set false for explicit history
/// windows, including before reset/replay. Programmatic scroll, layout and remount
/// never resume a frozen feed. True explicitly clears selection and follows the
/// rendered cursor; the reader must drain missing history from its applied cursor.
/// Always-follow projections cannot be frozen by this operation.
void setTerminalProjectionFollow(
  String handle,
  bool following,
  bool resumeAtEnd,
) => throw UnsupportedError(
  'Terminal projection access is available only to interpreted frontends.',
);

/// Scrolls within the local retained buffer in logical pixels and freezes feed,
/// preserving resumeAtEnd. Always-follow projections remain at the rendered end.
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
