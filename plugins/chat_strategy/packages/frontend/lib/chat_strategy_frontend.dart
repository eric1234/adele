import 'package:adele_ui/inspection_display.dart';
import 'package:adele_ui/main_content_bridge.dart';
import 'package:adele_ui/owning_backend_bridge.dart';
import 'package:adele_ui/rich_document_editor_bridge.dart';
import 'package:adele_ui/session_execution_bridge.dart';
import 'package:adele_ui/session_presentation_lifecycle_bridge.dart';
import 'package:chat_strategy_contract/chat_strategy_contract.dart';
import 'package:flutter/material.dart';

void initializeChatMainContent() {
  final context = readMainContentContext();
  if (context['strategyId'] != chatStrategyId.value) return;
  openMainContentPane('chat', 'Chat', false);
}

Future<Widget> buildChat() async {
  final client = ChatSessionServiceClient(
    OwningBackendRequestChannel(chatSessionServiceId),
  );
  final sessionId = currentSessionId();
  final stateRevision = readSessionExecution()['sessionStateRevision'] as int;
  ChatSessionSnapshot? snapshot;
  String failure = '';
  final result = await settleSessionOperation(client.snapshot(sessionId));
  if (result[0] == true) {
    snapshot = result[1] as ChatSessionSnapshot;
  } else {
    snapshot = null;
    failure = 'Chat history is unavailable. Retry to refresh.';
  }
  return SingleChildScrollView(
    padding: EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ChatFrontend(
          client: client,
          initialSnapshot: snapshot,
          sessionId: sessionId,
          initialFailure: failure,
          initialStateRevision: stateRevision,
        ),
        buildSessionExecutionStatus(),
      ],
    ),
  );
}

class ChatFrontend extends StatefulWidget {
  ChatFrontend({
    required this.client,
    required this.initialSnapshot,
    required this.sessionId,
    required this.initialFailure,
    required this.initialStateRevision,
  });
  final ChatSessionServiceClient client;
  final ChatSessionSnapshot? initialSnapshot;
  final String sessionId;
  final String initialFailure;
  final int initialStateRevision;

  @override
  State<ChatFrontend> createState() => _ChatFrontendState();
}

class _ChatFrontendState extends State<ChatFrontend> {
  String editor = '';
  String draftMarkdown = '';
  String documentFailure = '';
  String importWarning = '';
  int editorRevision = 0;
  bool draftIsBlank = true;
  void Function() editorListener = () {};
  // The evaluator requires an explicit initializer to box nullable fields.
  // ignore: avoid_init_to_null
  ChatSessionSnapshot? snapshot = null;
  // ignore: avoid_init_to_null
  ChatEntry? acceptedEntry = null;
  // ignore: avoid_init_to_null
  Future<bool>? draftSave = null;
  final Map<String, String> runs = <String, String>{};
  void Function() listener = () {};
  Future<bool> Function() deactivation = () async => false;
  String sessionId = '';
  String failure = '';
  String historyFailure = '';
  String draftFailure = '';
  bool submitting = false;
  bool refreshing = false;
  bool refreshRequested = false;
  int sessionStateRevision = 0;
  int revision = 0;
  int draftRevision = 0;
  int savedDraftRevision = 0;
  bool disposed = false;

  @override
  void initState() {
    super.initState();
    sessionId = widget.sessionId;
    snapshot = widget.initialSnapshot;
    final initial = snapshot;
    if (initial != null) {
      associateActivity(initial);
      createEditor(initial.draftRequest);
    }
    historyFailure = widget.initialFailure;
    sessionStateRevision = widget.initialStateRevision;
    listener = () => executionChanged();
    subscribeSessionExecution(listener);
    deactivation = () => prepareToDeactivate();
    registerSessionPrepareToDeactivate(deactivation);
    // Materialization/terminal settlement can occur while buildChat hydrates,
    // before this view has a listener. Reconcile that missed semantic change.
    reconcileSessionState();
  }

  void executionChanged() {
    if (disposed) return;
    reconcileEditing();
    setState(() {});
    reconcileSessionState();
  }

  void reconcileSessionState() {
    final next = readSessionExecution()['sessionStateRevision'] as int;
    if (next == sessionStateRevision) return;
    sessionStateRevision = next;
    refreshCanonical();
  }

  Future<void> refreshCanonical() async {
    refreshRequested = true;
    if (refreshing || disposed) return;
    refreshing = true;
    while (refreshRequested && !disposed) {
      refreshRequested = false;
      final int requestedRevision = revision;
      final int requestedStateRevision =
          readSessionExecution()['sessionStateRevision'] as int;
      sessionStateRevision = requestedStateRevision;
      final ChatSessionServiceClient client = widget.client;
      final result = await settleSessionOperation(client.snapshot(sessionId));
      if (disposed) return;
      if (result[0] == true) {
        final next = result[1] as ChatSessionSnapshot;
        // An entry accepted while this read was pending must not be erased by
        // an older snapshot. Read again rather than merging invented history.
        if (requestedRevision != revision ||
            requestedStateRevision !=
                readSessionExecution()['sessionStateRevision']) {
          refreshRequested = true;
        } else {
          setState(() {
            // Only the first successful load restores the composer. Later
            // history reads must not replace this view's locally edited draft.
            if (snapshot == null && draftRevision == 0) {
              createEditor(next.draftRequest);
            }
            snapshot = next;
            associateActivity(next);
            historyFailure = '';
          });
          reconcileEditing();
        }
      } else {
        setState(() {
          historyFailure = 'Chat history is unavailable. Retry to refresh.';
        });
      }
    }
    refreshing = false;
  }

  void associateActivity(ChatSessionSnapshot current) {
    for (final ChatEntry entry in current.entries) {
      final runId = entry.runId;
      if (runId != null && !runs.containsKey(entry.id)) {
        final handle = openSessionRunActivity(runId);
        if (handle != null) runs[entry.id] = handle;
      }
    }
  }

  void createEditor(String markdown) {
    releaseEditor();
    final handle = createRichDocumentEditor(markdown, false);
    editor = handle;
    final data = snapshotRichDocumentEditor(handle);
    editorRevision = data['revision'] as int;
    draftMarkdown = markdown;
    draftIsBlank = data['isBlank'] == true;
    documentFailure = '';
    importWarning = data['unsupportedReason'] == null
        ? ''
        : 'This Markdown is not supported for rich editing. The original is '
              'preserved read-only and can be sent unchanged.';
    editorListener = () => editorChanged(handle);
    subscribeRichDocumentEditor(handle, editorListener);
    reconcileEditing();
  }

  void releaseEditor() {
    final handle = editor;
    editor = '';
    if (handle.isEmpty) return;
    unsubscribeRichDocumentEditor(handle, editorListener);
    releaseRichDocumentEditor(handle);
  }

  void reconcileEditing() {
    if (disposed || editor.isEmpty) return;
    setRichDocumentEditorEditingEnabled(
      editor,
      snapshot != null &&
          !submitting &&
          acceptedEntry == null &&
          readSessionExecution()['canStart'] == true,
    );
  }

  bool captureDraft() {
    if (editor.isEmpty) return true;
    final data = snapshotRichDocumentEditor(editor);
    final nextRevision = data['revision'] as int;
    if (nextRevision != editorRevision) {
      editorRevision = nextRevision;
      draftRevision++;
    }
    if (data['markdown'] == null) {
      documentFailure = data['error'] == 'composition_pending'
          ? 'Finish text composition before saving, sending, or leaving Chat.'
          : 'This edit cannot be saved as Markdown. Correct or Undo it before '
                'sending or leaving Chat. The last saved draft is unchanged.';
      return false;
    }
    documentFailure = '';
    draftMarkdown = data['markdown'] as String;
    draftIsBlank = data['isBlank'] == true;
    return true;
  }

  void editorChanged(String handle) {
    if (disposed || editor != handle) return;
    // While a write is in flight, its settlement takes the next snapshot. Native
    // notifications carry no content and cannot replace the latest document.
    if (draftSave != null) return;
    final previousRevision = draftRevision;
    final wasUnsafe = documentFailure.isNotEmpty;
    final safe = captureDraft();
    setState(() {});
    if (safe && (draftRevision != previousRevision || wasUnsafe)) {
      retryDraftSave();
    }
  }

  void retryDraftSave() {
    if (disposed || submitting) return;
    saveDraft();
  }

  Future<bool> saveDraft() async {
    if (disposed) return false;
    if (!captureDraft()) {
      setState(() {});
      return false;
    }
    final pending = draftSave;
    if (pending != null) return await pending;
    if (savedDraftRevision == draftRevision) return true;
    setState(() {
      draftFailure = '';
    });
    draftSave = persistDraft();
    return await draftSave!;
  }

  Future<bool> prepareToDeactivate() async {
    // An in-flight submission may still accept text or start a Run. Navigation
    // must leave this view intact until the user can retry after it settles.
    if (disposed || submitting) return false;
    return await saveDraft();
  }

  Future<bool> persistDraft() async {
    while (!disposed && savedDraftRevision != draftRevision) {
      final int requestedRevision = draftRevision;
      final String content = draftMarkdown;
      final ChatSessionServiceClient client = widget.client;
      final result = await settleSessionOperation(
        client.setDraftRequest(sessionId, content),
      );
      if (disposed) return false;
      final safe = captureDraft();
      if (result[0] != true) {
        setState(() {
          draftFailure = 'Draft was not saved. Your text is preserved.';
        });
        // A newer queued edit still gets its own attempt. Never retry the same
        // failed revision automatically, including after session_busy.
        if (!safe || requestedRevision == draftRevision) {
          draftSave = null;
          return false;
        }
      } else {
        savedDraftRevision = requestedRevision;
        if (draftFailure.isNotEmpty) {
          setState(() {
            draftFailure = '';
          });
        }
      }
      if (!safe) {
        setState(() {});
        draftSave = null;
        return false;
      }
    }
    draftSave = null;
    return !disposed;
  }

  Future<void> submit() async {
    if (disposed || submitting || snapshot == null) return;
    if (readSessionExecution()['canStart'] != true) return;
    // Read before disabling input: closing an input client is not an IME commit.
    if (acceptedEntry == null) {
      final safe = captureDraft();
      setState(() {});
      if (!safe || draftIsBlank || draftMarkdown.trim().isEmpty) return;
    }
    setState(() {
      submitting = true;
      failure = '';
    });
    reconcileEditing();
    if (acceptedEntry == null) {
      final saved = await saveDraft();
      if (disposed) return;
      if (!saved) {
        setState(() {
          submitting = false;
        });
        reconcileEditing();
        return;
      }
      final ChatSessionServiceClient client = widget.client;
      final result = await settleSessionOperation(
        client.submitDraftRequest(sessionId),
      );
      if (disposed) return;
      if (result[0] != true) {
        setState(() {
          failure = 'Message was not accepted. Your draft is preserved.';
          submitting = false;
        });
        reconcileEditing();
        return;
      }
      final entry = result[1] as ChatEntry;
      revision++;
      acceptedEntry = entry;
      // Backend acceptance owns clearing. A new owner is an explicit undo and
      // callback boundary: submitted content cannot become an unsent draft again.
      createEditor('');
      draftRevision++;
      savedDraftRevision = draftRevision;
      final current = snapshot!;
      final entries = <ChatEntry>[];
      entries.addAll(current.entries);
      if (!entries.any((existing) => existing.id == entry.id)) {
        entries.add(entry);
      }
      setState(() {
        snapshot = ChatSessionSnapshot(
          entries: entries,
          instructions: current.instructions,
          draftRequest: '',
        );
        draftFailure = '';
      });
    }
    final result = await settleSessionOperation(startSessionRun());
    if (disposed) return;
    if (result[0] != true) {
      setState(() {
        failure = 'Message accepted, but Run could not start. Retry Send.';
        submitting = false;
      });
      reconcileEditing();
      return;
    }
    final String runHandle = result[1] as String;
    runs[acceptedEntry!.id] = runHandle;
    acceptedEntry = null;
    executionChanged();
    // Scheduling may already have settled a very short Run before its handle
    // arrived. Canonical history is also refreshed at every later terminal.
    refreshCanonical();
    if (!disposed) {
      setState(() {
        submitting = false;
      });
      reconcileEditing();
    }
  }

  @override
  void dispose() {
    disposed = true;
    unregisterSessionPrepareToDeactivate(deactivation);
    unsubscribeSessionExecution(listener);
    releaseEditor();
    super.dispose();
  }

  List<Widget> activity(String runHandle) {
    final result = <Widget>[];
    final data = readSessionRunActivity(runHandle);
    final models = data['models'] as List<Map<String, Object?>>;
    for (final model in models.where(
      (model) => model['settlement'] == 'completed',
    )) {
      final visible = <Map<String, Object?>>[];
      final narration = <String>[];
      bool hasTools = false;
      String nativeText = '';
      for (final output in model['outputs'] as List<Map<String, Object?>>) {
        final kind = output['kind'];
        if (kind == 'text') {
          final text = output['content'] as String;
          if (text.trim().isNotEmpty) narration.add(text.trim());
        } else if (kind == 'tool') {
          hasTools = true;
          visible.add(output);
        } else if (kind == 'native' && output['presentation'] != null) {
          visible.add(output);
          final compact = output['compactText'] as String;
          if (nativeText.isEmpty && compact.trim().isNotEmpty) {
            nativeText = compact.trim();
          }
        }
      }
      if (visible.length == 1) {
        result.add(buildSessionActivity(visible[0]['handle'] as String));
      } else if (visible.length > 1) {
        String heading = '${visible.length} operations';
        if (hasTools && narration.isNotEmpty) {
          heading = narration.join(' ');
        } else if (nativeText.isNotEmpty) {
          heading = nativeText;
        }
        result.add(activityGroup(model['handle'] as String, heading));
      }
    }
    return result;
  }

  // A separate frame keeps each callback's handle out of the eval loop's
  // recycled locals. Group policy and its heading still belong to Chat.
  Widget activityGroup(String handle, String heading) => Padding(
    padding: EdgeInsets.only(bottom: 16),
    child: TextButton(
      onPressed: () {
        if (!disposed) inspectSessionActivity(handle);
      },
      child: Text(
        compactDisplayText(heading),
        style: TextStyle(fontSize: 12, color: Colors.grey),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final current = snapshot;
    final bool canSubmit =
        current != null &&
        !submitting &&
        readSessionExecution()['canStart'] == true;
    final List<Widget> children = <Widget>[
      Text('Chat', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      SizedBox(height: 16),
    ];
    if (current != null) {
      for (final ChatEntry entry in current.entries) {
        children.add(
          Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Align(
              alignment: entry.role == 'user'
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: entry.role == 'user'
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    entry.role == 'user' ? 'You' : 'ADELE',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 4),
                  Text(entry.content),
                ],
              ),
            ),
          ),
        );
        final runHandle = runs[entry.id];
        if (runHandle != null) children.addAll(activity(runHandle));
      }
    }
    if (failure.isNotEmpty) {
      children.add(Text(failure));
    }
    if (historyFailure.isNotEmpty) {
      children.add(Text(historyFailure));
      children.add(
        TextButton(
          onPressed: () {
            refreshCanonical();
          },
          child: Text('Retry history'),
        ),
      );
    }
    if (draftFailure.isNotEmpty) {
      children.add(Text(draftFailure));
      if (canSubmit && acceptedEntry == null) {
        children.add(
          TextButton(
            onPressed: () => retryDraftSave(),
            child: Text('Retry save'),
          ),
        );
      }
    }
    if (documentFailure.isNotEmpty) children.add(Text(documentFailure));
    if (importWarning.isNotEmpty) children.add(Text(importWarning));
    children.add(Text('Ask ADELE...'));
    if (editor.isNotEmpty) {
      children.add(
        SizedBox(height: 180, child: buildRichDocumentEditor(editor)),
      );
      children.add(
        Text(
          'Enter adds content. Use Send to submit. Selections spanning code and '
          'other blocks can be copied, but must be edited within one block.',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      );
    }
    if (canSubmit) {
      children.add(
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: () => submit(), child: Text('Send')),
        ),
      );
    } else {
      // The pin declares TextButton.onPressed as non-nullable. A non-actionable
      // label avoids a broken nullable callback while submission is unavailable.
      children.add(
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text('Send', style: TextStyle(color: Colors.grey)),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}
