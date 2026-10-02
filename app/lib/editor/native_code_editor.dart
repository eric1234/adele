import 'dart:async';

import 'package:code_forge/code_forge.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/re_highlight.dart';

/// Process-wide native initialization, deliberately absent from public UI APIs.
abstract final class NativeCodeEngine {
  static Future<void>? _initialization;

  static Future<void> initialize() => _initialization ??= RustLib.init();
}

/// An in-memory text/undo owner. No resource, file, session or save semantics.
final class NativeCodeBuffer {
  NativeCodeBuffer({
    required String text,
    this.language = 'dart',
    Future<void> Function()? initializeNative,
  }) : _initialText = text,
       _initializeNative = initializeNative ?? NativeCodeEngine.initialize {
    validateText(text);
    if (!const {'plain', 'dart', 'json', 'python'}.contains(language)) {
      throw ArgumentError.value(language, 'language', 'Unsupported language');
    }
  }

  static const maxScalars = 262144;
  static const maxUndoOperations = 128;
  final String language;
  final Future<void> Function() _initializeNative;
  String? _initialText;
  Future<void>? _initialization;
  _OwnedCodeController? _controller;
  UndoRedoController? _undo;
  _NativeCodeEditorState? _attachment;
  final _views = <NativeCodeView>{};
  final _observers = <VoidCallback>{};
  bool _disposed = false;
  bool _notificationPending = false;
  int _observedVersion = 0;
  int _snapshotReads = 0;

  bool get isDisposed => _disposed;
  bool get isInitialized => _controller != null && !_disposed;
  int get version => _requireController().contentVersion;

  @visibleForTesting
  int get snapshotReads => _snapshotReads;
  @visibleForTesting
  int get observerCount => _observers.length;

  Future<void> initialize() {
    _requireAlive();
    if (isInitialized) return Future<void>.value();
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    await _initializeNative();
    _requireAlive();
    final controller = _OwnedCodeController(this)
      ..maxLength = maxScalars
      ..enableLocalSuggestions = false;
    final undo = UndoRedoController(maxStackSize: maxUndoOperations);
    try {
      controller.withOwnerMutation(() {
        controller.replaceRange(0, 0, _initialText!);
        controller.pressDocumentHomeKey();
      });
      controller.setUndoController(undo);
      controller.interactionAllowed = () =>
          !_disposed && (_attachment?._canInteract ?? false);
      controller.interactionToken = () => _attachment?._activation;
      _controller = controller;
      _undo = undo;
      _initialText = null;
      _observedVersion = controller.contentVersion;
      controller.addListener(_changed);
      _scheduleNotification();
    } on Object {
      controller.dispose();
      undo.dispose();
      rethrow;
    }
  }

  void _requireAlive() {
    if (_disposed) throw StateError('Code buffer is disposed.');
  }

  _OwnedCodeController _requireController() {
    _requireAlive();
    return _controller ?? (throw StateError('Code buffer is not initialized.'));
  }

  void _changed() {
    if (_disposed) return;
    final current = _controller!.contentVersion;
    if (current == _observedVersion) return;
    _observedVersion = current;
    _scheduleNotification();
  }

  void _scheduleNotification() {
    if (_notificationPending || _disposed) return;
    _notificationPending = true;
    scheduleMicrotask(() {
      _notificationPending = false;
      if (_disposed) return;
      for (final observer in _observers.toList()) {
        if (!_observers.contains(observer)) continue;
        try {
          observer();
        } on Object catch (error, stack) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stack,
              library: 'ADELE native code editor',
              context: ErrorDescription('notifying a code buffer observer'),
            ),
          );
        }
      }
    });
  }

  VoidCallback observeChanges(VoidCallback observer) {
    _requireAlive();
    void listener() => observer();
    _observers.add(listener);
    return () => _observers.remove(listener);
  }

  /// One deliberate immutable, coherent full-text copy. Never called by the
  /// version listener or cursor/scroll retention machinery.
  Map<String, Object> snapshot() {
    final controller = _requireController();
    final version = controller.contentVersion;
    final text = controller.text;
    _snapshotReads++;
    return Map.unmodifiable({'text': text, 'version': version});
  }

  /// Trusted detached-buffer edit in UTF-16 coordinates. The range must be a scalar
  /// boundary and is validated before reaching Rust. Records normal undo.
  void replaceRangeUtf16(int start, int end, String replacement) {
    final controller = _requireController();
    if (_attachment != null) {
      throw StateError('Trusted range edits require a detached buffer.');
    }
    validateText(replacement);
    final text = controller.text;
    validateRange(text, start, end);
    final from = CodeForgeController.utf16ToScalarOffset(text, start);
    final to = CodeForgeController.utf16ToScalarOffset(text, end);
    if (controller.length - (to - from) + replacement.runes.length >
        maxScalars) {
      throw RangeError('Code buffer exceeds $maxScalars Unicode scalars.');
    }
    controller.withOwnerMutation(
      () => controller.replaceRange(from, to, replacement),
    );
    for (final view in _views) {
      view._selection = controller.selection;
      view._horizontalOffset = 0;
      view._verticalOffset = 0;
    }
  }

  /// Explicit loading/test replacement, only without a mounted view. Discards
  /// undo/redo and local view positions; remount never uses this operation.
  void replaceText(String text) {
    final controller = _requireController();
    if (_attachment != null) {
      throw StateError('Cannot replace a mounted buffer.');
    }
    validateText(text);
    controller.withOwnerMutation(() {
      controller.replaceRange(0, controller.length, text);
      controller.pressDocumentHomeKey();
      _undo!.clear();
    });
    for (final view in _views) {
      view._selection = const TextSelection.collapsed(offset: 0);
      view._horizontalOffset = 0;
      view._verticalOffset = 0;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    Object? failure;
    StackTrace? failureStack;
    void clean(VoidCallback action) {
      try {
        action();
      } on Object catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }

    // Revoke input and snapshots before callbacks or component teardown run.
    for (final view in _views.toList()) {
      clean(view.dispose);
    }
    _observers.clear();
    final controller = _controller;
    _controller = null;
    controller?.removeListener(_changed);
    if (controller != null) clean(controller.dispose);
    if (_undo != null) clean(_undo!.dispose);
    _undo = null;
    _initialText = null;
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  }

  static void validateText(String text) {
    var scalars = 0;
    for (var i = 0; i < text.length; i++, scalars++) {
      final unit = text.codeUnitAt(i);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i == text.length ||
            text.codeUnitAt(i) < 0xdc00 ||
            text.codeUnitAt(i) > 0xdfff) {
          throw ArgumentError('Unpaired UTF-16 high surrogate.');
        }
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        throw ArgumentError('Unpaired UTF-16 low surrogate.');
      }
    }
    if (scalars > maxScalars) {
      throw RangeError('Code buffer exceeds $maxScalars Unicode scalars.');
    }
  }

  static void validateRange(String text, int start, int end) {
    if (start < 0 || end < start || end > text.length) {
      throw RangeError('Invalid UTF-16 range [$start, $end).');
    }
    for (final offset in [start, end]) {
      if (offset > 0 &&
          offset < text.length &&
          text.codeUnitAt(offset - 1) >= 0xd800 &&
          text.codeUnitAt(offset - 1) <= 0xdbff &&
          text.codeUnitAt(offset) >= 0xdc00 &&
          text.codeUnitAt(offset) <= 0xdfff) {
        throw ArgumentError('UTF-16 endpoint splits a surrogate pair.');
      }
    }
  }
}

/// A retained local view identity, independent of its buffer and presentations.
/// Only one mounted view may consume a buffer, including a retired exit view.
final class NativeCodeView {
  NativeCodeView({required this.buffer, this.readOnly = false}) {
    buffer._requireAlive();
    buffer._views.add(this);
  }

  final NativeCodeBuffer buffer;
  final bool readOnly;
  bool _disposed = false;
  TextSelection _selection = const TextSelection.collapsed(offset: 0);
  double _horizontalOffset = 0;
  double _verticalOffset = 0;
  final _accesses = <NativeCodeAccess>{};
  _NativeCodeEditorState? _mounted;

  bool get isDisposed => _disposed || buffer.isDisposed;

  @visibleForTesting
  DeltaTextInputClient? get inputClientForTesting => _mounted?._inputClient;

  NativeCodeAccess createAccess({
    required bool Function() isActive,
    VoidCallback? onUnavailable,
  }) {
    if (isDisposed) throw StateError('Code view is disposed.');
    final access = NativeCodeAccess._(this, isActive, onUnavailable);
    _accesses.add(access);
    return access;
  }

  bool requestFocus() {
    final mounted = _mounted;
    if (isDisposed ||
        mounted == null ||
        !mounted._viewLive ||
        !mounted._ready ||
        !mounted._windowActive) {
      return false;
    }
    mounted._focus.requestFocus();
    return true;
  }

  Map<String, dynamic> readState() {
    if (isDisposed) throw StateError('Code view is disposed.');
    final mounted = _mounted;
    return Map.unmodifiable({
      'ready': mounted?._ready ?? false,
      'readOnly': readOnly,
      'version': buffer.isInitialized ? buffer.version : 0,
      'language': buffer.language,
      'focused': mounted?._canInteract ?? false,
      'horizontalOffset': mounted?._horizontal.hasClients == true
          ? mounted!._horizontal.offset
          : _horizontalOffset,
      'verticalOffset': mounted?._vertical.hasClients == true
          ? mounted!._vertical.offset
          : _verticalOffset,
    });
  }

  Map<String, dynamic> snapshot() {
    if (isDisposed) throw StateError('Code view is disposed.');
    final result = buffer.snapshot();
    final text = result['text']! as String;
    final selection = _mounted?._controller?.selection ?? _selection;
    return Map.unmodifiable({
      ...result,
      'selectionBase': CodeForgeController.scalarToUtf16Offset(
        text,
        selection.baseOffset,
      ),
      'selectionExtent': CodeForgeController.scalarToUtf16Offset(
        text,
        selection.extentOffset,
      ),
      'selectionUnit': 'utf16',
    });
  }

  /// Trusted host/test view positioning. Does not edit text or require focus.
  void selectUtf16(int base, int extent) {
    if (isDisposed) throw StateError('Code view is disposed.');
    final controller = buffer._requireController();
    final text = controller.text;
    NativeCodeBuffer.validateRange(
      text,
      base < extent ? base : extent,
      base < extent ? extent : base,
    );
    _selection = TextSelection(
      baseOffset: CodeForgeController.utf16ToScalarOffset(text, base),
      extentOffset: CodeForgeController.utf16ToScalarOffset(text, extent),
    );
    if (_mounted != null) {
      controller.withOwnerMutation(
        () => controller.setSelectionImmediately(_selection),
      );
    }
  }

  void scrollTo({required double horizontal, required double vertical}) {
    if (isDisposed) throw StateError('Code view is disposed.');
    if (!horizontal.isFinite ||
        !vertical.isFinite ||
        horizontal < 0 ||
        vertical < 0) {
      throw ArgumentError('Invalid editor scroll offset.');
    }
    _horizontalOffset = horizontal;
    _verticalOffset = vertical;
    _mounted?._restoreScroll();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    Object? failure;
    StackTrace? failureStack;
    for (final access in _accesses.toList()) {
      try {
        access.revoke();
        access._onUnavailable?.call();
      } on Object catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    buffer._views.remove(this);
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }
}

/// One presentation's permanently revocable grant. Never reused for remount by
/// another evaluator, even when that evaluator selects the same logical view.
final class NativeCodeAccess {
  NativeCodeAccess._(this.view, this._isActive, this._onUnavailable);
  final NativeCodeView view;
  final bool Function() _isActive;
  final VoidCallback? _onUnavailable;
  bool _revoked = false;
  _NativeCodeEditorState? _mount;
  final _observers = <VoidCallback>{};
  Widget? _widget;

  bool get isAvailable {
    if (_revoked || view.isDisposed) return false;
    try {
      if (_isActive() && !_revoked && !view.isDisposed) return true;
    } on Object {
      // A failed external liveness check cannot expand authority.
    }
    revoke();
    return false;
  }

  void _require() {
    if (!isAvailable) throw StateError('Code editor presentation is retired.');
  }

  Widget buildView() {
    _require();
    return _widget ??= _NativeCodeEditor(access: this);
  }

  Map<String, dynamic> readState() {
    _require();
    final value = view.readState();
    _require();
    return value;
  }

  Map<String, dynamic> snapshot() {
    _require();
    final value = view.snapshot();
    _require();
    return value;
  }

  VoidCallback observeChanges(VoidCallback listener) {
    _require();
    final detach = view.buffer.observeChanges(() {
      if (isAvailable) listener();
    });
    _observers.add(detach);
    return () {
      detach();
      _observers.remove(detach);
    };
  }

  void revoke() {
    if (_revoked) return;
    _revoked = true;
    try {
      _mount?._revoke();
    } finally {
      for (final detach in _observers.toList()) {
        detach();
      }
      _observers.clear();
      view._accesses.remove(this);
      _widget = null;
    }
  }
}

class _NativeCodeEditor extends StatefulWidget {
  const _NativeCodeEditor({required this.access});
  final NativeCodeAccess access;
  @override
  State<_NativeCodeEditor> createState() => _NativeCodeEditorState();
}

class _NativeCodeEditorState extends State<_NativeCodeEditor>
    with WidgetsBindingObserver {
  late final _EditorFocusNode _focus;
  late final ScrollController _horizontal;
  late final ScrollController _vertical;
  FindController? _find;
  _OwnedCodeController? _controller;
  final _pointers = <int>{};
  Object? _activation;
  Object? _inputGeneration;
  _ScopedCodeInput? _inputClient;
  bool _ready = false;
  bool _retired = false;
  bool _deactivating = false;
  bool _windowActive = true;
  Object? _failure;

  NativeCodeAccess get _access => widget.access;
  NativeCodeView get _view => _access.view;
  NativeCodeBuffer get _buffer => _view.buffer;
  bool get _viewLive => mounted && !_retired && _access.isAvailable;
  bool get _canInteract =>
      _viewLive && _ready && _windowActive && _focus.hasFocus;

  @override
  void initState() {
    super.initState();
    _focus = _EditorFocusNode(() => _viewLive && _ready && _windowActive)
      ..addListener(_focusChanged);
    _horizontal = ScrollController(
      initialScrollOffset: _view._horizontalOffset,
    );
    _vertical = ScrollController(initialScrollOffset: _view._verticalOffset);
    _windowActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_attach());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted || _retired) return;
    _windowActive = state == AppLifecycleState.resumed;
    if (!_windowActive) {
      _focusChanged();
      _focus.unfocus();
    }
  }

  Future<void> _attach() async {
    try {
      if (!_buffer.isInitialized) await _buffer.initialize();
      if (!_viewLive) return;
      if (_buffer._attachment != null || _access._mount != null) {
        throw StateError('A code buffer permits only one mounted view.');
      }
      _buffer._attachment = this;
      _view._mounted = this;
      _access._mount = this;
      final controller = _controller = _buffer._requireController();
      controller.readOnly = _view.readOnly;
      controller.withOwnerMutation(
        () => controller.setSelectionImmediately(_view._selection),
      );
      _find = FindController(controller);
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_viewLive) return;
        _restoreScroll();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_viewLive) return;
          _restoreScroll();
          setState(() => _ready = true);
          _buffer._scheduleNotification();
        });
        WidgetsBinding.instance.scheduleFrame();
      });
    } on Object catch (error) {
      if (!_viewLive) return;
      setState(() => _failure = error);
      _access._onUnavailable?.call();
    }
  }

  void _restoreScroll() {
    for (final (controller, offset) in [
      (_horizontal, _view._horizontalOffset),
      (_vertical, _view._verticalOffset),
    ]) {
      if (!controller.hasClients || !controller.position.hasContentDimensions) {
        continue;
      }
      controller.jumpTo(
        offset.clamp(
          controller.position.minScrollExtent,
          controller.position.maxScrollExtent,
        ),
      );
    }
  }

  void _capture() {
    final controller = _controller;
    if (controller != null && !controller.isDisposed) {
      _view._selection = controller.selection;
    }
    if (_horizontal.hasClients) _view._horizontalOffset = _horizontal.offset;
    if (_vertical.hasClients) _view._verticalOffset = _vertical.offset;
  }

  void _focusChanged() {
    if (_retired) return;
    if (_canInteract) {
      _activation ??= Object();
    } else {
      _activation = null;
      _inputGeneration = null;
      _inputClient = null;
      _cancelPointers();
      _capture();
      if (_controller?.isDisposed == false) {
        _controller!.cancelCompositionAndDetach();
      }
    }
  }

  void _cancelPointers() {
    for (final pointer in _pointers.toList()) {
      GestureBinding.instance.cancelPointer(pointer);
    }
    _pointers.clear();
  }

  void _revoke() {
    if (_retired) return;
    _capture();
    _retired = true;
    _activation = null;
    _inputGeneration = null;
    _inputClient = null;
    _cancelPointers();
    if (_controller?.isDisposed == false) {
      _controller!.cancelCompositionAndDetach();
    }
    _focus.unfocus();
    if (mounted && !_deactivating) setState(() {});
  }

  bool _tokenLive(Object? token) =>
      token != null && _canInteract && identical(_activation, token);

  @override
  Widget build(BuildContext context) {
    if (!_viewLive) return const SizedBox.shrink();
    if (_failure != null) return Text('Code editor unavailable: $_failure');
    final controller = _controller;
    if (controller == null) {
      return const Center(child: Text('Preparing code editor'));
    }
    final Mode language = switch (_buffer.language) {
      'dart' => langDart,
      'json' => langJson,
      'python' => langPython,
      _ => Mode(),
    };
    return _CodeInputBoundary(
      onPointer: (event) {
        if (event is PointerDownEvent) {
          if (!_viewLive || !_ready || !_windowActive) return;
          _focus.requestFocus();
          FocusManager.instance.applyFocusChangesIfNeeded();
          if (!_canInteract) {
            GestureBinding.instance.cancelPointer(event.pointer);
            return;
          }
          _pointers.add(event.pointer);
        } else if (event is PointerUpEvent || event is PointerCancelEvent) {
          _pointers.remove(event.pointer);
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            ignoring: !_ready,
            child: Opacity(
              opacity: _ready ? 1 : 0,
              child: CodeForge(
                controller: controller,
                undoController: _buffer._undo,
                findController: _find,
                focusNode: _focus,
                horizontalScrollController: _horizontal,
                verticalScrollController: _vertical,
                language: language,
                readOnly: _view.readOnly,
                lineWrap: false,
                autoFocus: false,
                enableFolding: false,
                enableGuideLines: false,
                enableLocalSuggestions: false,
                enableKeyboardSuggestions: false,
                keyboardShotcuts: const CodeForgeKeyboardShortcuts(
                  duplicate: _DisabledShortcut(),
                  shiftLineUp: _DisabledShortcut(),
                  shiftLineDown: _DisabledShortcut(),
                  deletWordBackward: _DisabledShortcut(),
                  deletWordForward: _DisabledShortcut(),
                  moveCursorToPreviousWord: _DisabledShortcut(),
                  moveCursorToNextWord: _DisabledShortcut(),
                  moveSelectionToPreviousWord: _DisabledShortcut(),
                  moveSelectionToNextWord: _DisabledShortcut(),
                  lspCodeActions: _DisabledShortcut(),
                  lspSignatureHelp: _DisabledShortcut(),
                  showFindBar: _DisabledShortcut(),
                  showFindAndReplaceBar: _DisabledShortcut(),
                  extendMutliCursorDownward: _DisabledShortcut(),
                  extendMutliCursorUpward: _DisabledShortcut(),
                ),
                interactionAllowed: () => _viewLive && _ready,
                inputClientFactory: (client) {
                  final token = _activation;
                  final generation = _inputGeneration = Object();
                  return _inputClient = _ScopedCodeInput(
                    client,
                    () =>
                        _tokenLive(token) &&
                        identical(_inputGeneration, generation),
                    () => !_view.readOnly,
                  );
                },
              ),
            ),
          ),
          if (!_ready) const Center(child: Text('Preparing code editor')),
        ],
      ),
    );
  }

  @override
  void deactivate() {
    _deactivating = true;
    _access.revoke();
    super.deactivate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (!_retired) _capture();
    _retired = true;
    _activation = null;
    _inputGeneration = null;
    _inputClient = null;
    _cancelPointers();
    if (_controller?.isDisposed == false) {
      _controller!.cancelCompositionAndDetach();
    }
    if (identical(_buffer._attachment, this)) _buffer._attachment = null;
    if (identical(_view._mounted, this)) _view._mounted = null;
    if (identical(_access._mount, this)) _access._mount = null;
    _focus.removeListener(_focusChanged);
    _find?.dispose();
    _focus.dispose();
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }
}

final class _EditorFocusNode extends FocusNode {
  _EditorFocusNode(this._allowed);
  final bool Function() _allowed;
  @override
  void requestFocus([FocusNode? node]) {
    if (_allowed()) super.requestFocus(node);
  }
}

/// Capture pointer-down before the component's render-object handlers. A normal
/// Listener receives hit-test dispatch after its child, too late to establish
/// the first click's focus/activation token before selecting text.
final class _CodeInputBoundary extends SingleChildRenderObjectWidget {
  const _CodeInputBoundary({required this.onPointer, required super.child});
  final void Function(PointerEvent) onPointer;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _CodeInputBoundaryRender(onPointer);
  @override
  void updateRenderObject(
    BuildContext context,
    _CodeInputBoundaryRender renderObject,
  ) {
    renderObject.onPointer = onPointer;
  }
}

final class _CodeInputBoundaryRender extends RenderProxyBox {
  _CodeInputBoundaryRender(this.onPointer);
  void Function(PointerEvent) onPointer;
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    result.add(BoxHitTestEntry(this, position));
    hitTestChildren(result, position: position);
    return true;
  }

  @override
  void handleEvent(PointerEvent event, covariant BoxHitTestEntry entry) =>
      onPointer(event);
}

/// Clipboard methods are virtual component entry points, so its keyboard/menu
/// routes share the same activation fence. There is no raw controller in EVC.
final class _OwnedCodeController extends CodeForgeController {
  _OwnedCodeController(this.owner);
  final NativeCodeBuffer owner;
  bool _clipboardBusy = false;

  _NativeCodeEditorState? get _mount => owner._attachment;

  Future<void> _clipboardAction(Future<void> Function() action) async {
    if (_clipboardBusy) return;
    final mount = _mount;
    final token = mount?._activation;
    if (mount == null || !mount._tokenLive(token)) return;
    _clipboardBusy = true;
    try {
      await action();
    } on Object {
      if (mount._tokenLive(token)) rethrow;
    } finally {
      _clipboardBusy = false;
    }
  }

  @override
  void notifyListeners() {
    // Teardown can close IME during Flutter's deactivate traversal. Accepted
    // content was already observed; a retired renderer must not repaint here.
    if (_mount?._retired ?? false) {
      owner._changed();
      return;
    }
    super.notifyListeners();
  }

  @override
  void addMultiCursor(int line, int character) {}

  @override
  set openedFile(String? file) {
    if (file != null) {
      throw UnsupportedError('Native code buffers have no file authority.');
    }
  }

  @override
  void saveFile() =>
      throw UnsupportedError('Saving belongs to the future Source Editor.');

  @override
  void refetchFile() =>
      throw UnsupportedError('Native code buffers have no file authority.');

  @override
  Future<void> copy() => _clipboardAction(() async {
    final mount = _mount;
    final token = mount?._activation;
    if (mount == null || !mount._tokenLive(token) || selection.isCollapsed) {
      return;
    }
    final text = this.text;
    final base = CodeForgeController.scalarToUtf16Offset(text, selection.start);
    final end = CodeForgeController.scalarToUtf16Offset(text, selection.end);
    await Clipboard.setData(ClipboardData(text: text.substring(base, end)));
  });

  @override
  Future<void> cut() => _clipboardAction(() async {
    final mount = _mount;
    final token = mount?._activation;
    if (mount == null ||
        !mount._tokenLive(token) ||
        readOnly ||
        selection.isCollapsed) {
      return;
    }
    final selected = selection;
    final version = contentVersion;
    final text = this.text;
    final base = CodeForgeController.scalarToUtf16Offset(text, selected.start);
    final end = CodeForgeController.scalarToUtf16Offset(text, selected.end);
    await Clipboard.setData(ClipboardData(text: text.substring(base, end)));
    if (!mount._tokenLive(token) ||
        isDisposed ||
        readOnly ||
        contentVersion != version ||
        selection != selected) {
      return;
    }
    replaceRange(selected.start, selected.end, '');
  });

  @override
  Future<void> paste() => _clipboardAction(() async {
    final mount = _mount;
    final token = mount?._activation;
    if (mount == null || !mount._tokenLive(token) || readOnly) return;
    final selected = selection;
    final version = contentVersion;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text == null ||
        !mount._tokenLive(token) ||
        isDisposed ||
        readOnly ||
        contentVersion != version ||
        selection != selected) {
      return;
    }
    NativeCodeBuffer.validateText(data!.text!);
    if (length - (selected.end - selected.start) + data.text!.runes.length >
        NativeCodeBuffer.maxScalars) {
      throw RangeError('Paste exceeds the code buffer admission bound.');
    }
    replaceRange(selected.start, selected.end, data.text!);
  });
}

/// A fresh client object for each activation. Returning A -> B -> A never
/// revives callbacks retained from A's previous native input connection.
final class _ScopedCodeInput with TextInputClient, DeltaTextInputClient {
  _ScopedCodeInput(this._delegate, this._live, this._editable);
  final DeltaTextInputClient _delegate;
  final bool Function() _live;
  final bool Function() _editable;

  @override
  TextEditingValue? get currentTextEditingValue =>
      _live() ? _delegate.currentTextEditingValue : null;
  @override
  AutofillScope? get currentAutofillScope => null;

  static void _validate(TextEditingValue value) {
    NativeCodeBuffer.validateText(value.text);
    final selection = value.selection;
    if (!selection.isValid) throw ArgumentError('Invalid input selection.');
    NativeCodeBuffer.validateRange(value.text, selection.start, selection.end);
    if (value.composing.isValid) {
      NativeCodeBuffer.validateRange(
        value.text,
        value.composing.start,
        value.composing.end,
      );
    }
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    if (!_live() || !_editable()) return;
    _validate(value);
    _delegate.updateEditingValue(value);
  }

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> deltas) {
    if (!_live() || !_editable()) return;
    var value = _delegate.currentTextEditingValue;
    if (value == null) return;
    for (final delta in deltas) {
      if (delta.oldText != value!.text) {
        throw ArgumentError('Stale input projection.');
      }
      NativeCodeBuffer.validateText(delta.oldText);
      if (delta is TextEditingDeltaInsertion) {
        NativeCodeBuffer.validateRange(
          delta.oldText,
          delta.insertionOffset,
          delta.insertionOffset,
        );
        NativeCodeBuffer.validateText(delta.textInserted);
      } else if (delta is TextEditingDeltaDeletion) {
        NativeCodeBuffer.validateRange(
          delta.oldText,
          delta.deletedRange.start,
          delta.deletedRange.end,
        );
      } else if (delta is TextEditingDeltaReplacement) {
        NativeCodeBuffer.validateRange(
          delta.oldText,
          delta.replacedRange.start,
          delta.replacedRange.end,
        );
        NativeCodeBuffer.validateText(delta.replacementText);
      }
      value = delta.apply(value);
      _validate(value);
    }
    if (_live()) _delegate.updateEditingValueWithDeltas(deltas);
  }

  @override
  void connectionClosed() {
    if (_live()) _delegate.connectionClosed();
  }

  @override
  void performAction(TextInputAction action) {
    if (_live()) _delegate.performAction(action);
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}
  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}
  @override
  void showAutocorrectionPromptRect(int start, int end) {}
}

final class _DisabledShortcut implements ShortcutActivator {
  const _DisabledShortcut();
  @override
  Iterable<LogicalKeyboardKey> get triggers => const [];
  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) => false;
  @override
  String debugDescribeKeys() => 'Disabled in ADELE E1';
}
