import 'dart:async';
import 'dart:collection';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'rich_document_markdown.dart';

/// In-memory, single-view owner. Document identity and saving belong to callers.
class NativeRichDocumentEditor extends ChangeNotifier {
  NativeRichDocumentEditor({required String markdown, bool readOnly = false})
    : _original = markdown,
      _readOnly = readOnly {
    try {
      _state = _RichEditorState(
        document: RichDocumentMarkdown.decode(markdown),
        readOnly: readOnly,
        observeInput: _observeInput,
      );
      _state!.editable = !readOnly;
      _transactions = _state!.transactionStream.listen((event) {
        if (_disposed || event.$1 != TransactionTime.after) return;
        final changed = event.$2.operations.any((operation) {
          if (operation is UpdateOperation) {
            return !mapEquals(operation.attributes, operation.oldAttributes);
          }
          return true;
        });
        if (!changed) return;
        _mutated = true;
        _revision++;
        notifyListeners();
      });
    } on FormatException catch (error) {
      _unsupportedReason = error.message;
    }
  }

  final String _original;
  final bool _readOnly;
  _RichEditorState? _state;
  StreamSubscription<EditorTransactionValue>? _transactions;
  _RichDocumentViewState? _view;
  _RichDocumentViewState? _pendingView;
  String? _unsupportedReason;
  bool _mutated = false;
  bool _disposed = false;
  bool _editingEnabled = true;
  bool _compositionPending = false;
  bool _inputSettling = false;
  int _inputSequence = 0;
  int _revision = 0;

  bool get isDisposed => _disposed;
  bool get readOnly => _readOnly || _unsupportedReason != null;
  bool get editingEnabled => !_disposed && !readOnly && _editingEnabled;
  String? get unsupportedReason => _unsupportedReason;

  /// Temporarily gates input without replacing the document or its undo history.
  /// Disabling is not an IME commit. Snapshot before disabling for finalization.
  void setEditingEnabled(bool enabled) {
    _checkLive();
    final effective = enabled && !readOnly;
    if (editingEnabled == effective) return;
    _editingEnabled = effective;
    _state?.inputEnabled = effective;
    _state?.editable = effective;
    if (effective) {
      _state?.selectionExtraInfo = {...?_state?.selectionExtraInfo}
        ..remove(selectionExtraInfoDoNotAttachTextService);
    }
    _view?.editingChanged();
    notifyListeners();
  }

  void _observeInput(TextEditingDelta delta) {
    final composing = delta.composing.isValid && !delta.composing.isCollapsed;
    if (delta is TextEditingDeltaNonTextUpdate &&
        !composing &&
        !_compositionPending &&
        !_inputSettling) {
      return;
    }
    final sequence = ++_inputSequence;
    final wasPending = _compositionPending || _inputSettling;
    _inputSettling = true;
    if (composing) _compositionPending = true;
    // In pinned desktop AppFlowy, accepted deltas finish their document and
    // selection work through microtasks. Fence intermediate replacement state,
    // including composition-only commits, until the following frame. Closing
    // the input service is not evidence that a composition was committed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || sequence != _inputSequence) return;
      final wasPending = _compositionPending || _inputSettling;
      _inputSettling = false;
      if (_state?.acceptsInput == true) _compositionPending = composing;
      if (wasPending != _compositionPending) notifyListeners();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
    if (!wasPending) notifyListeners();
  }

  /// Nonempty document transaction invalidation, not a persistence revision.
  int get revision => _revision;

  Map<String, Object?> snapshot() {
    _checkLive();
    final pending = _compositionPending || _inputSettling;
    return {
      'markdown': pending
          ? null
          : _mutated
          ? RichDocumentMarkdown.encode(_state!.document)
          : _original,
      'revision': revision,
      'readOnly': readOnly,
      'editingEnabled': editingEnabled,
      'isBlank': pending
          ? null
          : _state == null
          ? _original.trim().isEmpty
          : _isBlank(_state!.document.root),
      'unsupportedReason': unsupportedReason,
      if (pending) 'error': 'composition_pending',
    };
  }

  bool _isBlank(Node node) =>
      (node.delta?.toPlainText().trim().isEmpty ?? true) &&
      node.children.every(_isBlank);

  Widget buildView() {
    _checkLive();
    return NativeRichDocumentEditorView._(key: ObjectKey(this), editor: this);
  }

  void _checkLive() {
    if (_disposed) throw StateError('Rich document editor is disposed.');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _transactions?.cancel();
    _transactions = null;
    _state?.retire();
    final view = _view;
    if (view == null) {
      _disposeState();
    } else {
      view.retire();
    }
    _pendingView?.retire();
    super.dispose();
  }

  void _disposeState() {
    final state = _state;
    if (state == null) return;
    _state = null;
    state.detachInputGuard();
    state.dispose();
    // 6.2.0 does not release these owned notifiers in EditorState.dispose.
    state.editableNotifier.dispose();
    state.remoteSelections.dispose();
    state.toggledStyleNotifier.dispose();
  }
}

class _RichEditorState extends EditorState {
  _RichEditorState({
    required super.document,
    required this.readOnly,
    required this.observeInput,
  });

  final bool readOnly;
  final void Function(TextEditingDelta) observeInput;
  bool inputEnabled = true;
  bool viewActive = false;
  bool _retired = false;
  final _inputGuard = _CodeInputGuard();
  AppFlowyKeyboardService? _guardedService;

  bool get acceptsInput => viewActive && !_retired && !isDisposed && editable;

  @override
  UnmodifiableMapView<String, dynamic> get toggledStyle =>
      _touchesCode(this) ? UnmodifiableMapView({}) : super.toggledStyle;

  @override
  bool get sliceUpcomingAttributes =>
      !_touchesCode(this) && super.sliceUpcomingAttributes;

  void detachInputGuard() {
    _guardedService?.unregisterInterceptor(_inputGuard);
    _guardedService = null;
  }

  void retire() {
    _retired = true;
    viewActive = false;
    editable = false;
  }

  @override
  set editable(bool value) => super.editable =
      value && !readOnly && inputEnabled && viewActive && !_retired;

  @override
  set selection(Selection? value) {
    // AppFlowy attaches input on selection, even without focus or editability.
    // Fence queued selection callbacks before the retired subtree is removed.
    if (isDisposed || (value != null && (!viewActive || _retired))) return;
    final keyboard = service.keyboardService;
    if (value != null && !identical(keyboard, _guardedService)) {
      detachInputGuard();
      keyboard?.registerInterceptor(_inputGuard);
      _guardedService = keyboard;
    }
    if (!editable) {
      selectionExtraInfo = {
        ...?selectionExtraInfo,
        selectionExtraInfoDoNotAttachTextService: true,
      };
    }
    super.selection = value;
  }
}

bool _isCode(Node? node) => node?.type == RichDocumentMarkdown.codeBlockType;

bool _touchesCode(EditorState state) {
  final selection = state.selection;
  return selection != null && state.getNodesInSelection(selection).any(_isCode);
}

bool _crossesCode(EditorState state) =>
    state.selection?.isSingle == false && _touchesCode(state);

bool _codeBoundary(EditorState state, {required bool forward}) {
  final selection = state.selection;
  if (selection == null || !selection.isCollapsed) return false;
  final node = state.getNodeAtPath(selection.start.path);
  if (node == null ||
      selection.start.offset != (forward ? node.delta?.length : 0)) {
    return false;
  }
  final neighbor = forward
      ? node.findDownward((node) => node.delta != null)
      : node.previousNodeWhere((node) => node.delta != null);
  return _isCode(node) || _isCode(neighbor);
}

// Upstream IME replacement/deletion can merge unlike blocks independently of
// command shortcuts. Reject those ranges instead of dropping code metadata or
// reparenting list children. Within one code block normal IME editing is retained.
class _CodeInputGuard extends AppFlowyKeyboardServiceInterceptor {
  bool _reject(EditorState state) =>
      !(state as _RichEditorState).acceptsInput || _crossesCode(state);

  bool _observe(TextEditingDelta delta, EditorState state) {
    if (_reject(state)) return true;
    (state as _RichEditorState).observeInput(delta);
    return false;
  }

  @override
  Future<bool> interceptInsert(
    TextEditingDeltaInsertion insertion,
    EditorState editorState,
    List<CharacterShortcutEvent> characterShortcutEvents,
  ) async => _observe(insertion, editorState);

  @override
  Future<bool> interceptReplace(
    TextEditingDeltaReplacement replacement,
    EditorState editorState,
    List<CharacterShortcutEvent> characterShortcutEvents,
  ) async => _observe(replacement, editorState);

  @override
  Future<bool> interceptDelete(
    TextEditingDeltaDeletion deletion,
    EditorState editorState,
  ) async =>
      (deletion.deletedRange.isCollapsed &&
          _codeBoundary(editorState, forward: false)) ||
      _observe(deletion, editorState);

  @override
  Future<bool> interceptNonTextUpdate(
    TextEditingDeltaNonTextUpdate update,
    EditorState editorState,
    List<CharacterShortcutEvent> characterShortcutEvents,
  ) async => _observe(update, editorState);
}

Transaction? _codeEnter(EditorState state) {
  final selection = state.selection?.normalized;
  if (selection == null || !selection.isSingle) return null;
  final node = state.getNodeAtPath(selection.start.path)!;
  if (_isCode(node)) {
    return state.transaction..replaceText(
      node,
      selection.startIndex,
      selection.length,
      '\n',
      attributes: {},
    );
  }
  if (node.type != ParagraphBlockKeys.type ||
      node.path.length != 1 ||
      node.children.isNotEmpty ||
      !selection.isCollapsed ||
      selection.endIndex != node.delta?.length) {
    return null;
  }
  final text = node.delta!.toPlainText();
  final match = RegExp(
    r'^(?:`{3,}|~{3,})([A-Za-z0-9][A-Za-z0-9_+.-]*)?$',
  ).firstMatch(text);
  if (match == null || match.end != text.length) return null;
  final path = node.path;
  return state.transaction
    ..insertNode(path, RichDocumentMarkdown.codeBlockNode(language: match[1]))
    ..deleteNode(node)
    ..afterSelection = Selection.collapsed(Position(path: path));
}

CommandShortcutEvent _guardDelete(
  CommandShortcutEvent command, {
  required bool forward,
  bool word = false,
}) => command.copyWith(
  handler: (state) {
    if (_crossesCode(state) || _codeBoundary(state, forward: forward)) {
      return KeyEventResult.handled;
    }
    final selection = state.selection?.normalized;
    if (selection?.isCollapsed == true && word) {
      final node = state.getNodeAtPath(selection!.start.path)!;
      final neighbor = forward
          ? node.findDownward((node) => node.delta != null)
          : node.previousNodeWhere((node) => node.delta != null);
      if (_isCode(node) || _isCode(neighbor)) {
        // Upstream word movement can skip whitespace into another block and use
        // that block's offset to delete from this one. Keep the range local.
        final offset = selection.startIndex;
        final text = node.delta!.toPlainText();
        final fragment = forward
            ? text.substring(offset)
            : text.substring(0, offset);
        final length = (forward ? RegExp(r'^\s*\S*') : RegExp(r'\S*\s*$'))
            .firstMatch(fragment)!
            .group(0)!
            .length;
        unawaited(
          state.apply(
            state.transaction
              ..deleteText(node, forward ? offset : offset - length, length),
          ),
        );
        return KeyEventResult.handled;
      }
    }
    if (selection != null && !selection.isCollapsed && _touchesCode(state)) {
      unawaited(
        state.apply(
          state.transaction..deleteText(
            state.getNodeAtPath(selection.start.path)!,
            selection.startIndex,
            selection.length,
          ),
        ),
      );
      return KeyEventResult.handled;
    }
    return command.handler(state);
  },
);

class NativeRichDocumentEditorView extends StatefulWidget {
  const NativeRichDocumentEditorView._({super.key, required this.editor});

  final NativeRichDocumentEditor editor;

  @override
  State<NativeRichDocumentEditorView> createState() => _RichDocumentViewState();
}

class _RichDocumentViewState extends State<NativeRichDocumentEditorView> {
  final FocusNode _focus = FocusNode(debugLabel: 'rich document');
  bool _attached = false;
  bool _active = true;
  bool _focusDisposed = false;

  NativeRichDocumentEditor get owner => widget.editor;

  @override
  void initState() {
    super.initState();
    owner._checkLive();
    if (owner._view?._active == true || owner._pendingView != null) {
      throw StateError(
        'A rich document editor supports only one mounted view.',
      );
    }
    if (owner._view != null) {
      // A keyed ancestor can replace an inactive view before Flutter finalizes
      // disposal. Let those descendants release the shared service keys first.
      owner._pendingView = this;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || owner.isDisposed) return;
        if (owner._view != null) {
          throw StateError('The previous rich document view is still mounted.');
        }
        owner._pendingView = null;
        _attach();
        setState(() {});
      });
    } else {
      _attach();
    }
  }

  void _attach() {
    owner._view = this;
    _attached = true;
    owner._state?.viewActive = true;
    owner._state?.editable = owner.editingEnabled;
  }

  void editingChanged() {
    if (!owner.editingEnabled) _releaseInput();
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void _releaseInput({bool clearSelection = true}) {
    if (!_attached || owner._state == null) return;
    // Close synchronously while AppFlowy's service is still mounted. Flutter
    // focus notifications alone may arrive after a subtree has been removed.
    owner._state!.service.keyboardService?.closeKeyboard();
    if (clearSelection &&
        SchedulerBinding.instance.schedulerPhase !=
            SchedulerPhase.persistentCallbacks) {
      owner._state!.selection = null;
    }
    _focus.unfocus();
  }

  void retire() {
    _releaseInput();
    _focus.canRequestFocus = false;
    void removeView() {
      if (!mounted) return;
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (owner.isDisposed) {
          owner._disposeState();
          _disposeFocus();
        }
      });
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => removeView());
    } else {
      removeView();
    }
  }

  @override
  void deactivate() {
    _active = false;
    if (_attached) {
      owner._state?.viewActive = false;
      owner._state?.editable = false;
      _releaseInput(clearSelection: false);
    }
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
    if (_attached && !owner.isDisposed) {
      owner._state?.viewActive = true;
      owner._state?.editable = owner.editingEnabled;
    }
  }

  void _disposeFocus() {
    if (_focusDisposed) return;
    _focusDisposed = true;
    _focus.dispose();
  }

  @override
  void dispose() {
    if (identical(owner._pendingView, this)) owner._pendingView = null;
    if (_attached) {
      owner._state?.detachInputGuard();
      owner._view = null;
      if (owner.isDisposed) {
        owner._disposeState();
      } else {
        // Descendants have detached; notifying selection during deactivate would
        // ask AppFlowy overlays to rebuild while Flutter's tree is locked.
        owner._state?.selection = null;
      }
    }
    _disposeFocus();
    super.dispose();
  }

  Future<void> _paste() async {
    final state = owner._state;
    if (state == null ||
        !state.acceptsInput ||
        !mounted ||
        owner.isDisposed ||
        _crossesCode(state)) {
      return;
    }
    final selection = state.selection;
    final revision = owner.revision;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted ||
        !_active ||
        owner.isDisposed ||
        !state.acceptsInput ||
        !_focus.hasFocus ||
        owner.revision != revision ||
        state.selection != selection ||
        data?.text == null ||
        data!.text!.isEmpty) {
      return;
    }
    if (_touchesCode(state)) {
      final range = selection!.normalized;
      await state.apply(
        state.transaction..replaceText(
          state.getNodeAtPath(range.start.path)!,
          range.startIndex,
          range.length,
          data.text!.replaceAll('\r\n', '\n'),
          attributes: {},
        ),
      );
      return;
    }
    // Deliberately paste text, never HTML, files, image URLs, or native blocks.
    // Keep line breaks within this block. The upstream multi-block paste helper
    // reparents existing list children before recording Undo, losing them on Undo.
    await state.pasteSingleLineNode(
      paragraphNode(text: data.text!.replaceAll('\r\n', '\n')),
    );
  }

  Future<void> _copyCode({bool cut = false}) async {
    final state = owner._state;
    final selection = state?.selection;
    if (state == null ||
        selection == null ||
        selection.isCollapsed ||
        !mounted ||
        !_active ||
        owner.isDisposed ||
        (cut && (!state.acceptsInput || _crossesCode(state)))) {
      return;
    }
    final revision = owner.revision;
    final range = selection.normalized;
    // No HTML encoder or Markdown conversion participates in code clipboard data.
    await AppFlowyClipboard.setData(
      text: state.getTextInSelection(range).join('\n'),
    );
    if (!cut ||
        !mounted ||
        !_active ||
        owner.isDisposed ||
        !state.acceptsInput ||
        !_focus.hasFocus ||
        owner.revision != revision ||
        state.selection != selection) {
      return;
    }
    await state.apply(
      state.transaction..deleteText(
        state.getNodeAtPath(range.start.path)!,
        range.startIndex,
        range.length,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (owner.isDisposed || !_attached) return const SizedBox.shrink();
    if (owner.unsupportedReason != null) {
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Read-only Markdown: ${owner.unsupportedReason}'),
            SelectableText(owner._original),
          ],
        ),
      );
    }
    return Localizations.override(
      context: context,
      delegates: const [AppFlowyEditorLocalizations.delegate],
      child: AppFlowyEditor(
        editorState: owner._state!,
        focusNode: _focus,
        editable: owner.editingEnabled,
        editorStyle: EditorStyle.desktop(
          padding: const EdgeInsets.all(16),
          textSpanDecorator: (context, node, index, text, before, after) =>
              before,
        ),
        blockComponentBuilders: {
          PageBlockKeys.type: PageBlockComponentBuilder(),
          ParagraphBlockKeys.type: ParagraphBlockComponentBuilder(),
          HeadingBlockKeys.type: HeadingBlockComponentBuilder(),
          BulletedListBlockKeys.type: BulletedListBlockComponentBuilder(),
          NumberedListBlockKeys.type: NumberedListBlockComponentBuilder(),
          QuoteBlockKeys.type: QuoteBlockComponentBuilder(),
          RichDocumentMarkdown.codeBlockType: ParagraphBlockComponentBuilder(
            configuration: BlockComponentConfiguration(
              padding: (_) => const EdgeInsets.all(12),
              textStyle: (_, {textSpan}) =>
                  const TextStyle(fontFamily: 'monospace'),
            ),
            showPlaceholder: (_, _) => false,
          ),
        },
        blockWrapper: (context, {required node, required child}) =>
            !_isCode(node)
            ? child
            : DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: child,
              ),
        characterShortcutEvents: [
          CharacterShortcutEvent(
            key: 'code newline or fence',
            character: '\n',
            handler: (state) async {
              // Leave code IME deltas to the ordinary literal insertion path:
              // the shortcut helper maps space+LF to LF and has no IME range.
              if (_touchesCode(state)) return false;
              final transaction = _codeEnter(state);
              if (transaction == null) return false;
              await state.apply(transaction);
              return true;
            },
          ),
          for (final event in [
            insertNewLineAfterBulletedList,
            insertNewLineAfterNumberedList,
            insertNewLineAfterHeading,
            insertNewLine,
            formatAsteriskToBulletedList,
            formatMinusToBulletedList,
            formatNumberToNumberedList,
            formatDoubleQuoteToQuote,
            formatSignToHeading,
          ])
            event.copyWith(
              handler: (state) async =>
                  _touchesCode(state) ? false : event.handler(state),
            ),
        ],
        commandShortcutEvents: [
          ...arrowLeftKeys,
          ...arrowRightKeys,
          ...arrowUpKeys,
          ...arrowDownKeys,
          homeCommand,
          endCommand,
          pageUpCommand,
          pageDownCommand,
          selectAllCommand,
          copyCommand.copyWith(
            handler: (state) {
              if (!_touchesCode(state)) return copyCommand.handler(state);
              unawaited(_copyCode());
              return KeyEventResult.handled;
            },
          ),
          if (!owner.readOnly) ...[
            for (final command in [
              undoCommand,
              redoCommand,
              CommandShortcutEvent(
                key: 'code newline or fence',
                command: 'enter',
                getDescription: () =>
                    'Code newline or create fenced code block',
                handler: (state) {
                  if (_crossesCode(state)) return KeyEventResult.handled;
                  final transaction = _codeEnter(state);
                  if (transaction == null) return KeyEventResult.ignored;
                  unawaited(state.apply(transaction));
                  return KeyEventResult.handled;
                },
              ),
              CommandShortcutEvent(
                key: 'exit code block',
                command: 'alt+enter',
                getDescription: () => 'Continue in a paragraph after code',
                handler: (state) {
                  final selection = state.selection;
                  if (selection?.isSingle != true || !_touchesCode(state)) {
                    return KeyEventResult.ignored;
                  }
                  final path = selection!.start.path.next;
                  unawaited(
                    state.apply(
                      state.transaction
                        ..insertNode(path, paragraphNode())
                        ..afterSelection = Selection.collapsed(
                          Position(path: path),
                        ),
                    ),
                  );
                  return KeyEventResult.handled;
                },
              ),
              CommandShortcutEvent(
                key: 'literal code tab',
                command: 'tab',
                getDescription: () => 'Insert a tab in code',
                handler: (state) {
                  if (!_touchesCode(state)) return KeyEventResult.ignored;
                  final range = state.selection!.normalized;
                  if (range.isSingle) {
                    unawaited(
                      state.apply(
                        state.transaction..replaceText(
                          state.getNodeAtPath(range.start.path)!,
                          range.startIndex,
                          range.length,
                          '\t',
                          attributes: {},
                        ),
                      ),
                    );
                  }
                  return KeyEventResult.handled;
                },
              ),
              convertToParagraphCommand.copyWith(
                handler: (state) {
                  if (_codeBoundary(state, forward: false)) {
                    return KeyEventResult.handled;
                  }
                  final selection = state.selection;
                  final node = selection == null
                      ? null
                      : state.getNodeAtPath(selection.start.path);
                  if (selection?.isCollapsed == true &&
                      selection!.start.offset == 0 &&
                      node != null &&
                      (node.children.isNotEmpty || node.path.length > 1)) {
                    return KeyEventResult.handled;
                  }
                  return convertToParagraphCommand.handler(state);
                },
              ),
              _guardDelete(backspaceCommand, forward: false),
              _guardDelete(deleteLeftWordCommand, forward: false, word: true),
              _guardDelete(deleteLeftSentenceCommand, forward: false),
              _guardDelete(deleteCommand, forward: true),
              _guardDelete(deleteRightWordCommand, forward: true, word: true),
              for (final event in [
                toggleBoldCommand,
                toggleItalicCommand,
                toggleCodeCommand,
              ])
                event.copyWith(
                  handler: (state) => _touchesCode(state)
                      ? KeyEventResult.handled
                      : event.handler(state),
                ),
              cutCommand.copyWith(
                handler: (state) {
                  // Upstream collapsed Cut deletes the block, including the last
                  // editable paragraph. Only cut an explicit text selection.
                  if (state.selection == null || state.selection!.isCollapsed) {
                    return KeyEventResult.ignored;
                  }
                  if (_touchesCode(state)) {
                    unawaited(_copyCode(cut: true));
                    return KeyEventResult.handled;
                  }
                  return cutCommand.handler(state);
                },
              ),
              CommandShortcutEvent(
                key: 'paste plain text',
                command: 'ctrl+v,ctrl+shift+v',
                macOSCommand: 'cmd+v,cmd+shift+v',
                getDescription: () => 'Paste plain text',
                handler: (_) {
                  unawaited(_paste());
                  return KeyEventResult.handled;
                },
              ),
            ])
              command.copyWith(
                handler: (state) => (state as _RichEditorState).acceptsInput
                    ? command.handler(state)
                    : KeyEventResult.handled,
              ),
          ],
        ],
      ),
    );
  }
}
