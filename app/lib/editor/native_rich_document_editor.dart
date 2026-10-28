import 'dart:async';

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
  int _revision = 0;

  bool get isDisposed => _disposed;
  bool get readOnly => _readOnly || _unsupportedReason != null;
  String? get unsupportedReason => _unsupportedReason;

  /// Nonempty document transaction invalidation, not a persistence revision.
  int get revision => _revision;

  Map<String, Object?> snapshot() {
    _checkLive();
    return {
      'markdown': _mutated
          ? RichDocumentMarkdown.encode(_state!.document)
          : _original,
      'revision': revision,
      'readOnly': readOnly,
      'unsupportedReason': unsupportedReason,
    };
  }

  Widget buildView() {
    _checkLive();
    return _RichDocumentView(key: ObjectKey(this), owner: this);
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
    state.dispose();
    // 6.2.0 does not release these owned notifiers in EditorState.dispose.
    state.editableNotifier.dispose();
    state.remoteSelections.dispose();
    state.toggledStyleNotifier.dispose();
  }
}

class _RichEditorState extends EditorState {
  _RichEditorState({required super.document, required this.readOnly});

  final bool readOnly;
  bool viewActive = false;
  bool _retired = false;

  void retire() {
    _retired = true;
    viewActive = false;
    editable = false;
  }

  @override
  set editable(bool value) => super.editable = value && !_retired;

  @override
  set selection(Selection? value) {
    // AppFlowy attaches input on selection, even without focus or editability.
    // Fence queued selection callbacks before the retired subtree is removed.
    if (isDisposed || (value != null && (!viewActive || _retired))) return;
    if (readOnly) {
      selectionExtraInfo = {
        ...?selectionExtraInfo,
        selectionExtraInfoDoNotAttachTextService: true,
      };
    }
    super.selection = value;
  }
}

class _RichDocumentView extends StatefulWidget {
  const _RichDocumentView({super.key, required this.owner});

  final NativeRichDocumentEditor owner;

  @override
  State<_RichDocumentView> createState() => _RichDocumentViewState();
}

class _RichDocumentViewState extends State<_RichDocumentView> {
  final FocusNode _focus = FocusNode(debugLabel: 'rich document');
  bool _attached = false;
  bool _active = true;
  bool _focusDisposed = false;

  NativeRichDocumentEditor get owner => widget.owner;

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
    owner._state?.editable = !owner.readOnly;
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
      owner._state?.editable = !owner.readOnly;
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
    if (state == null || !state.editable || !mounted || owner.isDisposed) {
      return;
    }
    final selection = state.selection;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted ||
        owner.isDisposed ||
        !state.editable ||
        !_focus.hasFocus ||
        state.selection != selection ||
        data?.text == null ||
        data!.text!.isEmpty) {
      return;
    }
    // Deliberately paste text, never HTML, files, image URLs, or native blocks.
    // Keep line breaks within this block. The upstream multi-block paste helper
    // reparents existing list children before recording Undo, losing them on Undo.
    await state.pasteSingleLineNode(
      paragraphNode(text: data.text!.replaceAll('\r\n', '\n')),
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
        editable: !owner.readOnly,
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
        },
        characterShortcutEvents: [
          insertNewLineAfterBulletedList,
          insertNewLineAfterNumberedList,
          insertNewLineAfterHeading,
          insertNewLine,
          formatAsteriskToBulletedList,
          formatMinusToBulletedList,
          formatNumberToNumberedList,
          formatDoubleQuoteToQuote,
          formatSignToHeading,
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
          copyCommand,
          if (!owner.readOnly) ...[
            undoCommand,
            redoCommand,
            convertToParagraphCommand.copyWith(
              handler: (state) {
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
            backspaceCommand,
            deleteLeftWordCommand,
            deleteLeftSentenceCommand,
            deleteCommand,
            deleteRightWordCommand,
            toggleBoldCommand,
            toggleItalicCommand,
            toggleCodeCommand,
            cutCommand.copyWith(
              handler: (state) {
                // Upstream collapsed Cut deletes the block, including the last
                // editable paragraph. Only cut an explicit text selection.
                if (state.selection == null || state.selection!.isCollapsed) {
                  return KeyEventResult.ignored;
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
          ],
        ],
      ),
    );
  }
}
