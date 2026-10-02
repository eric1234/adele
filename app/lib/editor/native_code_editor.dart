import 'package:code_forge/code_forge.dart';
import 'package:flutter/material.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/re_highlight.dart';

/// One open, supplied-text editor. CodeForge owns editing semantics; ADELE owns
/// the controller/undo lifetime and the interpreted presentation's access to it.
final class NativeCodeEditor extends ChangeNotifier {
  NativeCodeEditor({
    required String text,
    this.readOnly = false,
    this.language = 'dart',
  }) : _initialText = text {
    if (!const {'plain', 'dart', 'json', 'python'}.contains(language)) {
      throw ArgumentError.value(
        language,
        'language',
        'Unsupported language hint',
      );
    }
  }

  static Future<void>? _library;
  static Future<void> initializeLibrary() => _library ??= RustLib.init();

  final bool readOnly;
  final String language;
  String? _initialText;
  Future<void>? _initialization;
  CodeForgeController? _controller;
  UndoRedoController? _undo;
  _EditorViewState? _view;
  bool _closed = false;
  bool _released = false;
  int _revision = 0;

  bool get isDisposed => _closed;
  bool get isInitialized => !_closed && _controller != null;

  Future<void> initialize() {
    _checkOpen();
    if (isInitialized) return Future.value();
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    await initializeLibrary();
    _checkOpen();
    final controller = CodeForgeController()
      ..text = _initialText!
      ..pressDocumentHomeKey();
    final undo = UndoRedoController();
    controller.setUndoController(undo);
    controller.addListener(_changed);
    _controller = controller;
    _undo = undo;
    _initialText = null;
  }

  void _checkOpen() {
    if (_closed) throw StateError('Code editor is closed.');
  }

  CodeForgeController get _readyController {
    _checkOpen();
    return _controller ?? (throw StateError('Code editor is not initialized.'));
  }

  void _changed() {
    if (_closed) return;
    // CodeForge notifications include selection/layout changes. This is a UI
    // invalidation revision, not a content or filesystem version.
    _revision++;
    notifyListeners();
  }

  Map<String, dynamic> readState() {
    _checkOpen();
    return Map.unmodifiable({
      'ready': isInitialized,
      'revision': _revision,
      'readOnly': readOnly,
      'language': language,
    });
  }

  /// Explicit text observation. No whole-document read occurs in _changed.
  /// This is not a save transaction or a claim about uncommitted IME text.
  Map<String, dynamic> snapshot() =>
      Map.unmodifiable({'text': _readyController.text, 'revision': _revision});

  Widget buildView({VoidCallback? onUnavailable}) {
    _readyController;
    return _EditorView(
      key: ObjectKey(this),
      editor: this,
      onUnavailable: onUnavailable,
    );
  }

  bool requestFocus() {
    if (_closed || _view == null) return false;
    _view!._focus.requestFocus();
    return true;
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    // Let a mounted CodeForge widget detach before disposing its controller.
    notifyListeners();
    if (_view == null) _release();
    super.dispose();
  }

  void _release() {
    if (_released) return;
    _released = true;
    _controller?.removeListener(_changed);
    _controller?.requestImeReset = null;
    _controller?.userCodeAction = null;
    _controller?.setUndoController(null);
    _controller?.dispose();
    _undo?.clear();
    _undo?.dispose();
    _controller = null;
    _undo = null;
    _initialText = null;
  }
}

class _EditorView extends StatefulWidget {
  const _EditorView({super.key, required this.editor, this.onUnavailable});
  final NativeCodeEditor editor;
  final VoidCallback? onUnavailable;

  @override
  State<_EditorView> createState() => _EditorViewState();
}

class _EditorViewState extends State<_EditorView> {
  final _focus = FocusNode();
  final _horizontal = ScrollController();
  final _vertical = ScrollController();
  FindController? _find;
  bool _attached = false;

  @override
  void initState() {
    super.initState();
    final editor = widget.editor;
    if (!editor.isDisposed && editor._view == null) {
      editor._view = this;
      _attached = true;
      _find = FindController(editor._readyController);
      editor.addListener(_ownerChanged);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onUnavailable?.call();
      });
    }
  }

  void _ownerChanged() {
    if (!widget.editor.isDisposed || !mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.editor._release(),
    );
    widget.onUnavailable?.call();
  }

  @override
  Widget build(BuildContext context) {
    final editor = widget.editor;
    if (editor.isDisposed) return const SizedBox.shrink();
    if (!_attached) return const Text('This editor is already displayed.');
    final Mode mode = switch (editor.language) {
      'dart' => langDart,
      'json' => langJson,
      'python' => langPython,
      _ => Mode(),
    };
    return CodeForge(
      controller: editor._readyController,
      undoController: editor._undo,
      findController: _find,
      focusNode: _focus,
      horizontalScrollController: _horizontal,
      verticalScrollController: _vertical,
      readOnly: editor.readOnly,
      language: mode,
      enableLocalSuggestions: false,
      enableFolding: false,
      enableKeyboardSuggestions: false,
    );
  }

  @override
  void dispose() {
    final editor = widget.editor;
    if (_attached) {
      editor.removeListener(_ownerChanged);
      editor._view = null;
      editor._controller?.requestImeReset = null;
      editor._controller?.userCodeAction = null;
      _find!.dispose();
      _find!.findInputFocusNode.dispose();
      _find!.replaceInputFocusNode.dispose();
      if (editor.isDisposed) editor._release();
    }
    _focus.dispose();
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }
}
