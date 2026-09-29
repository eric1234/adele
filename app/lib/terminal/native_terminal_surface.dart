import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm2/xterm.dart' as xterm;

/// Native, in-memory emulator owner. No execution or product identity is needed.
///
/// [maxLines] bounds each buffer including its viewport (default 2,000, minimum
/// 24). All output is parsed in order; no additional transcript is retained.
/// Only one mounted view, including an exit-retained view, may attach at a time.
final class NativeTerminalSurface {
  NativeTerminalSurface({
    bool readOnly = false,
    int maxLines = 2000,
    void Function(String)? onInput,
    void Function(String)? onResponse,
    void Function(int columns, int rows)? onResize,
    void Function(String text, bool Function() isActive)? onScopedInput,
    void Function(int columns, int rows, bool Function() isActive)?
    onScopedResize,
  }) : _readOnly = readOnly,
       _projectionRows = null,
       _alwaysFollow = false,
       _maxLines = maxLines,
       _onInput = onInput,
       _onResponse = onResponse,
       _onResize = onResize,
       _onScopedInput = onScopedInput,
       _onScopedResize = onScopedResize {
    if (onInput != null && onScopedInput != null ||
        onResize != null && onScopedResize != null) {
      throw ArgumentError('Choose either scoped or synchronous callbacks.');
    }
    if (maxLines < 24) throw ArgumentError.value(maxLines, 'maxLines', '>= 24');
    _terminal = _Emulator(maxLines: maxLines)
      ..focusInput(false)
      ..onOutput = _response
      ..onTitleChange = _setTitle;
  }

  /// Separate, presentation-only pipe projection. The interactive constructor
  /// and its PTY/parser/layout authority are deliberately unchanged.
  NativeTerminalSurface.projection({
    required int rows,
    bool alwaysFollow = false,
    int maxLines = 200,
  }) : _readOnly = true,
       _projectionRows = rows,
       _alwaysFollow = alwaysFollow,
       _maxLines = maxLines {
    if (rows != 6 && rows != 20) {
      throw ArgumentError.value(rows, 'rows', '6 or 20');
    }
    if (maxLines < 24) throw ArgumentError.value(maxLines, 'maxLines', '>= 24');
    _terminal = _Emulator(maxLines: maxLines, projectionRows: rows)
      ..focusInput(false);
  }

  static const int maxTitleCodeUnits = 160;
  static const int maxProjectionFeedCodeUnits = 1024;
  static const int maxProjectionRepeatCount = 1024;

  final int? _projectionRows;
  final bool _alwaysFollow;
  final int _maxLines;
  bool _resumeAtEnd = true;
  bool _following = true;
  int _acceptedCodeUnits = 0;
  int _lineAdvances = 0;
  int _firstRetainedLine = 0;
  String? _projectionHighSurrogate;
  double? _projectionRequestedOffset;
  final _projectionObservers = <VoidCallback>{};
  bool _projectionNotificationPending = false;

  void _requireProjection() {
    _requireTerminal();
    if (_projectionRows == null) throw StateError('Not a pipe projection.');
  }

  Map<String, Object> readProjection() {
    _requireProjection();
    final position = _attached?._projectionScrollPosition;
    return Map.unmodifiable({
      'following': _following,
      'alwaysFollow': _alwaysFollow,
      'resumeAtEnd': _resumeAtEnd,
      'columns': 80,
      'rows': _projectionRows!,
      'maxLines': _maxLines,
      'maxFeedCodeUnits': maxProjectionFeedCodeUnits,
      'historyWindowCodeUnits': _maxLines - _projectionRows - 2,
      'acceptedCodeUnits': _acceptedCodeUnits,
      'lineAdvances': _lineAdvances,
      'firstRetainedLine': _firstRetainedLine,
      'retainedLines': _requireTerminal().buffer.height,
      'scrollOffset': position?.pixels ?? 0.0,
      'maxScrollOffset': position?.maxScrollExtent ?? 0.0,
    });
  }

  VoidCallback observeProjection(VoidCallback observer) {
    _requireProjection();
    void listener() => observer();
    _projectionObservers.add(listener);
    return () => _projectionObservers.remove(listener);
  }

  void _projectionChanged() {
    if (_projectionNotificationPending || isDisposed) return;
    _projectionNotificationPending = true;
    scheduleMicrotask(() {
      _projectionNotificationPending = false;
      for (final observer in _projectionObservers.toList()) {
        if (!_projectionObservers.contains(observer)) continue;
        try {
          observer();
        } on Object {
          // Observation cannot interrupt the native feed or other observers.
        }
      }
    });
  }

  int feedProjection(String text, int lineBudget) {
    _requireProjection();
    if (!_following || lineBudget <= 0) return 0;
    final terminal = _requireTerminal();
    final target = _lineAdvances + math.min(lineBudget, _projectionRows!);
    final end = math.min(text.length, maxProjectionFeedCodeUnits);
    var accepted = 0;
    while (accepted < end && _lineAdvances < target) {
      var count = 1;
      final unit = text.codeUnitAt(accepted);
      if (unit >= 0xd800 && unit <= 0xdbff && accepted + 1 < text.length) {
        final next = text.codeUnitAt(accepted + 1);
        if (next >= 0xdc00 && next <= 0xdfff) count = 2;
      }
      if (accepted + count > end) break;
      var output = text.substring(accepted, accepted + count);
      final pending = _projectionHighSurrogate;
      _projectionHighSurrogate = null;
      if (count == 1 &&
          unit >= 0xd800 &&
          unit <= 0xdbff &&
          accepted + 1 == text.length) {
        // The pin decodes surrogate pairs only within a write String. Carry at
        // most one accepted unit across caller-supplied chunk boundaries.
        _projectionHighSurrogate = output;
        output = '';
      }
      if (pending != null) output = pending + output;
      final before = terminal.buffer;
      final cursor = before.absoluteCursorY;
      final anchor = before.lines[before.height - 1];
      final anchorIndex = anchor.index;
      try {
        if (output.isNotEmpty) terminal.write(output);
      } on UnsupportedError {
        // A failed call acknowledges no prefix. Retire the partial rendering so
        // a caller cannot mistake it for faithfully consumed source or resume it.
        dispose();
        return -1;
      }
      final after = terminal.buffer;
      if (identical(before, after)) {
        final evicted = anchor.attached
            ? math.max(0, anchorIndex - anchor.index)
            : 0;
        _firstRetainedLine += evicted;
        _lineAdvances += math.max(0, after.absoluteCursorY - cursor + evicted);
      }
      accepted += count;
    }
    _acceptedCodeUnits += accepted;
    if (accepted != 0) {
      _attached?._scrollProjectionToEnd();
      _projectionChanged();
    }
    return accepted;
  }

  void resetProjection() {
    _requireProjection();
    final previous = _requireTerminal();
    _attached?._controller.clearSelection();
    _terminal = _Emulator(maxLines: _maxLines, projectionRows: _projectionRows)
      ..focusInput(false);
    _acceptedCodeUnits = 0;
    _lineAdvances = 0;
    _firstRetainedLine = 0;
    _projectionHighSurrogate = null;
    _following = true;
    _projectionRequestedOffset = null;
    _attached?._replaceProjectionTerminal();
    previous.dispose();
    _projectionChanged();
  }

  void setProjectionFollow(bool following, {bool resumeAtEnd = true}) {
    _requireProjection();
    if (_resumeAtEnd != resumeAtEnd) {
      _resumeAtEnd = resumeAtEnd;
      _projectionChanged();
    }
    if (following) _attached?._controller.clearSelection();
    _setProjectionFollowing(following);
  }

  void _setProjectionFollowing(bool following) {
    following = _alwaysFollow || following;
    if (_following != following) {
      _following = following;
      _projectionChanged();
    }
    if (following) {
      _projectionRequestedOffset = null;
      _attached?._scrollProjectionToEnd();
    }
  }

  void scrollProjection(double offset) {
    _requireProjection();
    if (!offset.isFinite) throw ArgumentError.value(offset, 'offset');
    if (_alwaysFollow) {
      _attached?._scrollProjectionToEnd();
      return;
    }
    _setProjectionFollowing(false);
    _projectionRequestedOffset = offset;
    _attached?._scrollProjectionTo(offset);
  }

  /// Host-selected authority can only be narrowed, never expanded by a view.
  final bool _readOnly;
  bool _inputStopped = false;
  bool get readOnly => _readOnly || _inputStopped;
  void Function(String)? _onInput;
  void Function(String)? _onResponse;
  void Function(int, int)? _onResize;
  void Function(String, bool Function())? _onScopedInput;
  void Function(int, int, bool Function())? _onScopedResize;
  _Emulator? _terminal;
  _NativeTerminalViewState? _attached;
  String? _title;
  final _titleObservers = <VoidCallback>{};
  bool _titleNotificationPending = false;

  bool get isDisposed => _terminal == null;

  /// Latest untrusted window title, normalized to a bounded single-line label.
  /// Null means no usable title. Retained independently of view attachment.
  String? get title => _title;

  /// Coalesced title invalidations, not output notifications or an initial replay.
  /// Read [title] after subscribing. Detachment is immediate and idempotent;
  /// observer failures cannot interrupt parsing or other observers.
  VoidCallback observeTitle(VoidCallback observer) {
    _requireTerminal();
    void listener() => observer();
    _titleObservers.add(listener);
    return () => _titleObservers.remove(listener);
  }

  void _setTitle(String raw) {
    if (isDisposed) return;
    final normalized = raw
        .replaceAll(
          RegExp(
            r'[\u00ad\u061c\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]',
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'[\x00-\x20\x7f-\x9f\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+',
          ),
          ' ',
        )
        .trim();
    final label = StringBuffer();
    for (final rune in normalized.runes) {
      // Never retain invalid UTF-16 or split a supplementary character.
      if (rune >= 0xd800 && rune <= 0xdfff) continue;
      if (label.length + (rune > 0xffff ? 2 : 1) > maxTitleCodeUnits) break;
      label.writeCharCode(rune);
    }
    final text = label.toString().trimRight();
    final title = text.isEmpty ? null : text;
    if (_title == title) return;
    _title = title;
    if (_titleNotificationPending) return;
    _titleNotificationPending = true;
    scheduleMicrotask(() {
      _titleNotificationPending = false;
      for (final observer in _titleObservers.toList()) {
        if (!_titleObservers.contains(observer)) continue;
        try {
          observer();
        } on Object {
          // Observation must never become terminal execution authority.
        }
      }
    });
  }

  /// Retains the screen and local copy/scroll while permanently fencing input.
  void stopInput() {
    if (_inputStopped || isDisposed) return;
    _inputStopped = true;
    _attached?._rebuild();
  }

  /// Sets owner geometry, including before any presentation is attached.
  void resize(int columns, int rows) =>
      _requireTerminal().resize(columns, rows);

  /// Synchronous ordered text feed, preserving parser state across calls.
  /// Late output after explicit disposal is rejected, not silently replayed.
  void write(String output) {
    final terminal = _requireTerminal();
    _withOutput(_response, () => terminal.write(output));
  }

  /// Native protocol replies are owner-scoped and work without a mounted view.
  /// Clipboard, URL, notification, and transfer authority is never installed.
  void _response(String output) {
    if (!isDisposed && !readOnly) _onResponse?.call(output);
  }

  T _withOutput<T>(void Function(String) sink, T Function() action) {
    final terminal = _requireTerminal();
    final previous = terminal.onOutput;
    terminal.onOutput = sink;
    try {
      return action();
    } finally {
      terminal.onOutput = isDisposed ? null : previous;
    }
  }

  _Emulator _requireTerminal() =>
      _terminal ?? (throw StateError('Terminal surface is disposed.'));

  /// Builds a presentation, not a new emulator. Access is rechecked on delivery.
  Widget buildView({
    required bool Function() isActive,
    VoidCallback? onUnavailable,
  }) {
    _requireTerminal();
    return _NativeTerminalView(
      key: UniqueKey(),
      surface: this,
      isActive: isActive,
      onUnavailable: onUnavailable,
    );
  }

  /// Idempotent resource retirement. Queued view actions become inert immediately;
  /// mounted Flutter resources detach on the next frame, not during layout.
  void dispose() {
    final terminal = _terminal;
    if (terminal == null) return;
    _terminal = null;
    _onInput = null;
    _onResponse = null;
    _onResize = null;
    _onScopedInput = null;
    _onScopedResize = null;
    _titleObservers.clear();
    _projectionObservers.clear();
    terminal.onOutput = null;
    terminal.onTitleChange = null;
    terminal.dispose();
    _attached?._ownerDisposed();
  }
}

// Bounds also cover output-requested geometry changes, not only Flutter layout.
final class _Emulator extends xterm.Terminal {
  _Emulator({required super.maxLines, this.projectionRows})
    : super(
        platform: switch (defaultTargetPlatform) {
          TargetPlatform.android => xterm.TerminalTargetPlatform.android,
          TargetPlatform.iOS => xterm.TerminalTargetPlatform.ios,
          TargetPlatform.fuchsia => xterm.TerminalTargetPlatform.fuchsia,
          TargetPlatform.linux => xterm.TerminalTargetPlatform.linux,
          TargetPlatform.macOS => xterm.TerminalTargetPlatform.macos,
          TargetPlatform.windows => xterm.TerminalTargetPlatform.windows,
        },
        onClipboardStore: (_, _) {},
        onClipboardQuery: (_) => null,
        onColorQuery: (_, _) => null,
        onColorSchemeQuery: () => null,
      ) {
    if (projectionRows != null) super.resize(80, projectionRows!);
  }

  final int? projectionRows;

  @override
  bool get lineFeedMode => projectionRows != null || super.lineFeedMode;

  @override
  void repeatPreviousCharacter(int count) {
    // The pin otherwise loops an unbounded CSI REP count inside one parser
    // operation. Reject excessive projection work rather than silently changing
    // captured output. PTY emulation retains its existing behavior.
    if (projectionRows != null &&
        count > NativeTerminalSurface.maxProjectionRepeatCount) {
      throw UnsupportedError('Terminal projection repeat limit exceeded.');
    }
    super.repeatPreviousCharacter(count);
  }

  // xterm otherwise accumulates an iTerm2 clipboard transcript even when its
  // clipboard callback denies access. This slice never authorizes that capture.
  @override
  void startITerm2ClipboardCapture(String selector) {}

  @override
  void resize(int width, int height, [int? pixelWidth, int? pixelHeight]) {
    if (projectionRows != null) return;
    if (width <= 0 || height <= 0) return;
    super.resize(
      width.clamp(1, 1000),
      height.clamp(1, maxLines),
      pixelWidth,
      pixelHeight,
    );
  }
}

class _NativeTerminalView extends StatefulWidget {
  const _NativeTerminalView({
    super.key,
    required this.surface,
    required this.isActive,
    this.onUnavailable,
  });

  final NativeTerminalSurface surface;
  final bool Function() isActive;
  final VoidCallback? onUnavailable;

  @override
  State<_NativeTerminalView> createState() => _NativeTerminalViewState();
}

class _NativeTerminalViewState extends State<_NativeTerminalView> {
  late final NativeTerminalSurface _surface = widget.surface;
  _ViewTerminal? _terminal;
  late final _ViewController _controller = _ViewController(this);
  late final ScrollController _projectionScroll = _ProjectionScrollController(
    _projectionUserScrolled,
  );
  final _projectionViewKey = GlobalKey<xterm.TerminalViewState>();
  double _projectionGridWidth = 0;
  int _projectionScrollRevision = 0;
  bool _projectionFollowScheduled = false;
  bool _retired = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_surface._projectionRows == null) return;
    // Match the pinned renderer's widest printable ASCII cell, including
    // platform fallback fonts and accessibility scaling, without reflow.
    final painter = TextPainter(
      text: TextSpan(
        text: List.generate(
          94,
          (index) => String.fromCharCode(33 + index),
        ).join('\n'),
        style: const xterm.TerminalStyle().toTextStyle(),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    _projectionGridWidth = (painter.width * 80).ceilToDouble();
    painter.dispose();
  }

  ScrollPosition? get _projectionScrollPosition =>
      _projectionScroll.hasClients &&
          _projectionScroll.position.hasContentDimensions
      ? _projectionScroll.position
      : null;

  void _replaceProjectionTerminal() {
    _terminal?.dispose();
    _terminal = _ViewTerminal(this, _surface._requireTerminal());
    _rebuild();
    _scrollProjectionToEnd();
  }

  void _scrollProjectionToEnd() {
    if (!_surface._following || _projectionFollowScheduled) return;
    _projectionFollowScheduled = true;
    _projectionScrollRevision++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _projectionFollowScheduled = false;
      if (!_available || !_surface._following) return;
      final position = _projectionScrollPosition;
      if (position != null) position.jumpTo(_projectionFollowOffset(position));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  double _projectionFollowOffset(ScrollPosition position) {
    final nativeView = _projectionViewKey.currentState;
    if (nativeView == null) return position.minScrollExtent;
    // Fixed emulator rows include unused screen padding. The physical viewport
    // can be much shorter; following its scroll extent would hide early output.
    final cursorBottom =
        (_surface._requireTerminal().buffer.absoluteCursorY + 1) *
        nativeView.renderTerminal.lineHeight;
    return (cursorBottom - position.viewportDimension).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
  }

  void _scrollProjectionTo(double offset) {
    final revision = ++_projectionScrollRevision;
    void apply() {
      if (!_available || revision != _projectionScrollRevision) return;
      final position = _projectionScrollPosition;
      if (position != null) {
        position.jumpTo(
          offset.clamp(position.minScrollExtent, position.maxScrollExtent),
        );
      }
    }

    apply();
    // Prefix replay can finish before a frame lays out the newly filled buffer.
    // Apply again against that extent, not only the old/empty viewport's extent.
    WidgetsBinding.instance.addPostFrameCallback((_) => apply());
  }

  void _projectionUserScrolled() {
    if (!_available || _surface._alwaysFollow) return;
    final position = _projectionScrollPosition;
    if (position == null) return;
    if (position.pixels < _projectionFollowOffset(position) - 0.5) {
      _projectionScrollRevision++;
      _surface._setProjectionFollowing(false);
    } else if (_surface._resumeAtEnd && _controller.selection == null) {
      _surface._setProjectionFollowing(true);
    }
    if (!_surface._following) {
      _surface._projectionRequestedOffset = position.pixels;
    }
    _surface._projectionChanged();
  }

  void _projectionOffsetChanged() {
    if (_available) _surface._projectionChanged();
  }

  bool get _available {
    if (_retired || !mounted || _surface.isDisposed) return false;
    try {
      if (widget.isActive()) return true;
    } on Object {
      // A failing native liveness predicate must not grant access.
    }
    _retired = true;
    return false;
  }

  @override
  void initState() {
    super.initState();
    final surface = widget.surface;
    if (!_available || surface._attached != null) {
      _retired = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onUnavailable?.call();
      });
      return;
    }
    surface._attached = this;
    _terminal = _ViewTerminal(this, surface._requireTerminal());
    if (surface._projectionRows != null) {
      _projectionScroll.addListener(_projectionOffsetChanged);
      if (surface._projectionRequestedOffset case final offset?) {
        _scrollProjectionTo(offset);
      }
    }
  }

  @override
  void deactivate() {
    if (_surface._projectionRows != null && !_surface._following) {
      _surface._projectionRequestedOffset = _projectionScrollPosition?.pixels;
    }
    // Deliver an authorized blur before retiring the mount. Disposal still
    // clears emulator focus silently when presentation access was revoked.
    _terminal?.focusInput(false);
    // A deactivated mount never lends its authority to a replacement mount.
    _retired = true;
    _terminal?.dispose();
    _terminal = null;
    if (identical(_surface._attached, this)) _surface._attached = null;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    // GlobalKey reparenting must fail explicitly, not revive captured actions or
    // leave a disconnected TerminalView competing with a fresh attachment.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onUnavailable?.call();
    });
  }

  void _ownerDisposed() {
    _retired = true;
    _terminal?.dispose();
    _terminal = null;
    _rebuild();
  }

  void _rebuild() {
    void rebuild() {
      if (mounted) setState(() {});
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => rebuild());
    } else {
      rebuild();
    }
  }

  @override
  Widget build(BuildContext context) {
    final terminal = _terminal;
    if (terminal == null || widget.surface.isDisposed) {
      // Let the old render subtree detach before disposing its controller.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _controller.dispose(),
      );
      return const Text('Terminal surface unavailable.');
    }
    final projection = _surface._projectionRows != null;
    final view = xterm.TerminalView(
      terminal,
      key: projection ? _projectionViewKey : null,
      controller: _controller,
      readOnly: widget.surface.readOnly || !_available,
      autoResize: !projection,
      scrollController: projection ? _projectionScroll : null,
      shortcuts: projection
          ? const {
              SingleActivator(
                LogicalKeyboardKey.keyC,
                control: true,
                shift: true,
              ): CopySelectionTextIntent.copy,
              SingleActivator(LogicalKeyboardKey.keyC, meta: true):
                  CopySelectionTextIntent.copy,
              SingleActivator(LogicalKeyboardKey.keyA, control: true):
                  SelectAllTextIntent(SelectionChangedCause.keyboard),
              SingleActivator(LogicalKeyboardKey.keyA, meta: true):
                  SelectAllTextIntent(SelectionChangedCause.keyboard),
            }
          : null,
    );
    if (!projection) return view;
    return LayoutBuilder(
      builder: (context, constraints) {
        _scrollProjectionToEnd();
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: math.max(_projectionGridWidth, constraints.maxWidth),
            height: constraints.maxHeight,
            child: MediaQuery.removePadding(
              context: context,
              removeLeft: true,
              removeRight: true,
              removeTop: true,
              removeBottom: true,
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  physics: _surface._alwaysFollow
                      ? const NeverScrollableScrollPhysics()
                      : null,
                ),
                child: Actions(
                  dispatcher: _ProjectionActionDispatcher(this),
                  actions: const {},
                  child: view,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _retired = true;
    _terminal?.dispose();
    _controller.dispose();
    _projectionScroll.dispose();
    if (identical(_surface._attached, this)) {
      _surface._attached = null;
    }
    super.dispose();
  }
}

/// User-originated motion only. Direction notifications can remain non-idle
/// during layout or programmatic movement and must not authorize live resumption.
final class _ProjectionScrollController extends ScrollController {
  _ProjectionScrollController(this.onUserScroll);

  final VoidCallback onUserScroll;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _ProjectionScrollPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    onUserScroll: onUserScroll,
  );
}

final class _ProjectionScrollPosition extends ScrollPositionWithSingleContext {
  _ProjectionScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.onUserScroll,
  });

  final VoidCallback onUserScroll;
  bool _pointerScroll = false;
  bool _userBallistic = false;

  @override
  void pointerScroll(double delta) {
    _pointerScroll = true;
    try {
      super.pointerScroll(delta);
    } finally {
      _pointerScroll = false;
    }
  }

  @override
  void beginActivity(ScrollActivity? newActivity) {
    _userBallistic =
        newActivity is BallisticScrollActivity &&
        (activity is DragScrollActivity || _userBallistic);
    super.beginActivity(newActivity);
  }

  @override
  void didUpdateScrollPositionBy(double delta) {
    if (_pointerScroll || activity is DragScrollActivity || _userBallistic) {
      onUserScroll();
    }
    super.didUpdateScrollPositionBy(delta);
  }
}

/// The pinned native paste action reads Clipboard even for read-only views.
/// Projection mode denies that action before the read, not merely its output.
final class _ProjectionActionDispatcher extends ActionDispatcher {
  const _ProjectionActionDispatcher(this._view);

  final _NativeTerminalViewState _view;

  @override
  Object? invokeAction(
    Action<Intent> action,
    Intent intent, [
    BuildContext? context,
  ]) {
    if (!_view._available || intent is PasteTextIntent) return null;
    return super.invokeAction(action, intent, context);
  }

  @override
  (bool, Object?) invokeActionIfEnabled(
    Action<Intent> action,
    Intent intent, [
    BuildContext? context,
  ]) {
    if (!_view._available || intent is PasteTextIntent) return (false, null);
    return super.invokeActionIfEnabled(action, intent, context);
  }
}

/// The pinned widget's paste action awaits Clipboard and then clears selection,
/// even after unmount. Both its captured terminal and controller must be inert.
final class _ViewController extends xterm.TerminalController {
  _ViewController(this._view);

  final _NativeTerminalViewState _view;
  bool _disposed = false;

  @override
  void clearSelection() {
    if (!_disposed && _view._available) super.clearSelection();
  }

  @override
  xterm.BufferRange? selectionFor(xterm.Buffer buffer) =>
      !_disposed && _view._available ? super.selectionFor(buffer) : null;

  @override
  void setSelection(
    xterm.CellAnchor base,
    xterm.CellAnchor extent, {
    xterm.SelectionMode? mode,
  }) {
    if (_disposed || !_view._available) {
      base.dispose();
      extent.dispose();
      return;
    }
    if (_view._surface._projectionRows != null) {
      _view._surface._setProjectionFollowing(false);
    }
    super.setSelection(base, extent, mode: mode);
  }

  @override
  void dispose() {
    if (_disposed) return;
    super.clearSelection();
    _disposed = true;
    super.dispose();
  }
}

/// Private, version-specific facade for xterm2's native widget, not a second
/// emulator or a plugin API. Every UI effect captures this exact mount. Rendering
/// reads the owner's state; parser operations always run on the owner emulator.
final class _ViewTerminal extends xterm.Terminal {
  _ViewTerminal(this._view, this._engine)
    : super(
        platform: _engine.platform,
        onClipboardStore: (_, _) {},
        onClipboardQuery: (_) => null,
        onColorQuery: (_, _) => null,
        onColorSchemeQuery: () => null,
      ) {
    _engine.addListener(notifyListeners);
  }

  final _NativeTerminalViewState _view;
  final _Emulator _engine;
  bool _disposed = false;
  bool _focused = false;
  (int, int)? _reportedSize;
  NativeTerminalSurface get _owner => _view._surface;
  bool get _available =>
      !_disposed && _view._available && identical(_owner._attached, _view);
  bool get _interactive => _available && !_owner.readOnly;

  T _input<T>(T unavailable, T Function() action) {
    if (!_interactive) return unavailable;
    return _owner._withOutput((data) {
      if (!_interactive) return;
      _owner._onInput?.call(data);
      _owner._onScopedInput?.call(data, () => _interactive);
    }, action);
  }

  @override
  bool keyInput(
    xterm.TerminalKey key, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
    bool superKey = false,
    bool capsLock = false,
    bool numLock = false,
    xterm.TerminalKeyEventType type = xterm.TerminalKeyEventType.press,
    String? text,
  }) => _input(
    false,
    () => _engine.keyInput(
      key,
      shift: shift,
      alt: alt,
      ctrl: ctrl,
      superKey: superKey,
      capsLock: capsLock,
      numLock: numLock,
      type: type,
      text: text,
    ),
  );

  @override
  void textInput(String text) =>
      _input<void>(null, () => _engine.textInput(text));

  @override
  void paste(String text) => _input<void>(null, () => _engine.paste(text));

  @override
  void focusInput(bool focused) {
    // xterm does not deduplicate focusInput, including an already-blurred detach.
    if (_disposed || _focused == focused) return;
    _focused = focused;
    _input<void>(null, () => _engine.focusInput(focused));
  }

  @override
  bool mouseInput(
    xterm.TerminalMouseButton button,
    xterm.TerminalMouseButtonState buttonState,
    xterm.CellOffset position, {
    bool motion = false,
    xterm.TerminalMouseModifiers modifiers = xterm.TerminalMouseModifiers.none,
    xterm.CellOffset? pixelPosition,
  }) => _input(
    false,
    () => _engine.mouseInput(
      button,
      buttonState,
      position,
      motion: motion,
      modifiers: modifiers,
      pixelPosition: pixelPosition,
    ),
  );

  @override
  void resize(int width, int height, [int? pixelWidth, int? pixelHeight]) {
    if (!_available || width <= 0 || height <= 0) return;
    final previous = (_engine.viewWidth, _engine.viewHeight);
    _owner._withOutput((data) {
      if (_interactive) _owner._onResponse?.call(data);
    }, () => _engine.resize(width, height, pixelWidth, pixelHeight));
    final size = (_engine.viewWidth, _engine.viewHeight);
    if (_interactive && size != previous) {
      _owner._onResize?.call(size.$1, size.$2);
    }
    // A fresh mount must submit its own authority even when its geometry matches
    // the emulator: a queued resize from the previous mount may be revoked.
    if (_interactive && size != _reportedSize) {
      _reportedSize = size;
      _owner._onScopedResize?.call(size.$1, size.$2, () => _interactive);
    }
  }

  // Theme-query policy is owner-scoped and deliberately declines these queries.
  @override
  void reportColorSchemeChange() {}

  @override
  void write(String data) =>
      throw UnsupportedError('Use the native owner feed.');

  @override
  void clear() =>
      throw UnsupportedError('The view does not own emulator state.');

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _engine.removeListener(notifyListeners);
    if (!_owner.isDisposed && identical(_owner._attached, _view)) {
      _owner._withOutput((_) {}, () => _engine.focusInput(false));
    }
    super.dispose();
  }

  @override
  xterm.Buffer get buffer => _engine.buffer;
  @override
  int get viewWidth => _engine.viewWidth;
  @override
  int get viewHeight => _engine.viewHeight;
  @override
  xterm.CursorStyle get cursor => _engine.cursor;
  @override
  bool get cursorBlinkMode => _engine.cursorBlinkMode;
  @override
  bool get cursorVisibleMode => _engine.cursorVisibleMode;
  @override
  xterm.TerminalCursorType? get applicationCursorType =>
      _engine.applicationCursorType;
  @override
  bool get cursorLineHighlightMode => _engine.cursorLineHighlightMode;
  @override
  bool get reverseDisplayMode => _engine.reverseDisplayMode;
  @override
  int get colorRevision => _engine.colorRevision;
  @override
  Iterable<MapEntry<int, int>> get indexedColorOverrides =>
      _engine.indexedColorOverrides;
  @override
  Iterable<MapEntry<int, int>> get specialColorOverrides =>
      _engine.specialColorOverrides;
  @override
  int? get foregroundColorOverride => _engine.foregroundColorOverride;
  @override
  int? get backgroundColorOverride => _engine.backgroundColorOverride;
  @override
  int? get cursorColorOverride => _engine.cursorColorOverride;
  @override
  int? get selectionColorOverride => _engine.selectionColorOverride;
  @override
  int? get selectionForegroundColorOverride =>
      _engine.selectionForegroundColorOverride;
  @override
  // Read-only scrolling is local even when output enables application scrolling.
  bool get isUsingAltBuffer => !_owner.readOnly && _engine.isUsingAltBuffer;
  @override
  xterm.MouseMode get mouseMode =>
      _owner.readOnly ? xterm.MouseMode.none : _engine.mouseMode;
  @override
  bool get mouseShiftCaptureMode => _engine.mouseShiftCaptureMode;
  @override
  bool get altSendsEscapeMode => _engine.altSendsEscapeMode;
  @override
  bool get altEscPrefixMode => _engine.altEscPrefixMode;
  @override
  String? hyperlinkAt(xterm.CellOffset position) =>
      _engine.hyperlinkAt(position);
  @override
  int hyperlinkIdAt(xterm.CellOffset position) =>
      _engine.hyperlinkIdAt(position);
}
