import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
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
      ..onOutput = _response;
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

  bool get isDisposed => _terminal == null;

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
    terminal.onOutput = null;
    terminal.dispose();
    _attached?._ownerDisposed();
  }
}

// Bounds also cover output-requested geometry changes, not only Flutter layout.
final class _Emulator extends xterm.Terminal {
  _Emulator({required super.maxLines})
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
      );

  // xterm otherwise accumulates an iTerm2 clipboard transcript even when its
  // clipboard callback denies access. This slice never authorizes that capture.
  @override
  void startITerm2ClipboardCapture(String selector) {}

  @override
  void resize(int width, int height, [int? pixelWidth, int? pixelHeight]) {
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
  bool _retired = false;

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
  }

  @override
  void deactivate() {
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
    return xterm.TerminalView(
      terminal,
      controller: _controller,
      readOnly: widget.surface.readOnly || !_available,
    );
  }

  @override
  void dispose() {
    _retired = true;
    _terminal?.dispose();
    _controller.dispose();
    if (identical(_surface._attached, this)) {
      _surface._attached = null;
    }
    super.dispose();
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
