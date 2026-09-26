import 'package:adele_ui/inspection_display.dart';
import 'package:adele_ui/owning_backend_bridge.dart';
import 'package:adele_ui/session_execution_bridge.dart';
import 'package:chat_strategy_contract/chat_strategy_contract.dart';
import 'package:flutter/material.dart';

Future<Widget> buildChat() async {
  final client = ChatSessionServiceClient(
    OwningBackendRequestChannel(chatSessionServiceId),
  );
  final sessionId = currentSessionId();
  ChatSessionSnapshot? snapshot;
  String failure = '';
  final result = await settleSessionOperation(client.snapshot(sessionId));
  if (result[0] == true) {
    snapshot = result[1] as ChatSessionSnapshot;
  } else {
    snapshot = null;
    failure = 'Chat history is unavailable. Retry to refresh.';
  }
  return ChatFrontend(
    client: client,
    initialSnapshot: snapshot,
    sessionId: sessionId,
    initialFailure: failure,
  );
}

class ChatFrontend extends StatefulWidget {
  ChatFrontend({
    required this.client,
    required this.initialSnapshot,
    required this.sessionId,
    required this.initialFailure,
  });
  final ChatSessionServiceClient client;
  final ChatSessionSnapshot? initialSnapshot;
  final String sessionId;
  final String initialFailure;

  @override
  State<ChatFrontend> createState() => _ChatFrontendState();
}

class _ChatFrontendState extends State<ChatFrontend> {
  TextEditingController controller = TextEditingController();
  // The evaluator requires an explicit initializer to box nullable fields.
  // ignore: avoid_init_to_null
  ChatSessionSnapshot? snapshot = null;
  // ignore: avoid_init_to_null
  ChatEntry? acceptedEntry = null;
  // ignore: avoid_init_to_null
  Future<bool>? draftSave = null;
  final Map<String, String> runs = <String, String>{};
  void Function() listener = () {};
  String sessionId = '';
  String failure = '';
  String historyFailure = '';
  String draftFailure = '';
  bool submitting = false;
  bool refreshing = false;
  bool refreshRequested = false;
  bool wasExecuting = false;
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
      // The pinned evaluator's text setter falls through to an unimplemented
      // superclass setter. Constructor text restores without that bridge bug.
      controller.dispose();
      controller = TextEditingController(text: initial.draftRequest);
    }
    historyFailure = widget.initialFailure;
    final execution = readSessionExecution();
    wasExecuting =
        execution['running'] == true || execution['advancing'] == true;
    listener = () => executionChanged();
    subscribeSessionExecution(listener);
  }

  void executionChanged() {
    if (disposed) return;
    final execution = readSessionExecution();
    final bool executing =
        execution['running'] == true || execution['advancing'] == true;
    final bool terminal = wasExecuting && !executing;
    wasExecuting = executing;
    setState(() {});
    if (terminal) refreshCanonical();
  }

  Future<void> refreshCanonical() async {
    refreshRequested = true;
    if (refreshing || disposed) return;
    refreshing = true;
    while (refreshRequested && !disposed) {
      refreshRequested = false;
      final int requestedRevision = revision;
      final ChatSessionServiceClient client = widget.client;
      final result = await settleSessionOperation(client.snapshot(sessionId));
      if (disposed) return;
      if (result[0] == true) {
        final next = result[1] as ChatSessionSnapshot;
        // An entry accepted while this read was pending must not be erased by
        // an older snapshot. Read again rather than merging invented history.
        if (requestedRevision != revision) {
          refreshRequested = true;
        } else {
          setState(() {
            // Only the first successful load restores the composer. Later
            // history reads must not replace this view's locally edited draft.
            if (snapshot == null && draftRevision == 0) {
              controller.dispose();
              controller = TextEditingController(text: next.draftRequest);
            }
            snapshot = next;
            historyFailure = '';
          });
        }
      } else {
        setState(() {
          historyFailure = 'Chat history is unavailable. Retry to refresh.';
        });
      }
    }
    refreshing = false;
  }

  void draftChanged(String value) {
    if (disposed || submitting || acceptedEntry != null) return;
    draftRevision++;
    retryDraftSave();
  }

  void retryDraftSave() {
    if (disposed || submitting) return;
    saveDraft();
  }

  Future<bool> saveDraft() async {
    final pending = draftSave;
    if (pending != null) return await pending;
    if (savedDraftRevision == draftRevision) return true;
    setState(() {
      draftFailure = '';
    });
    draftSave = persistDraft();
    return await draftSave!;
  }

  Future<bool> persistDraft() async {
    while (!disposed && savedDraftRevision != draftRevision) {
      final int requestedRevision = draftRevision;
      final String content = controller.text;
      final ChatSessionServiceClient client = widget.client;
      final result = await settleSessionOperation(
        client.setDraftRequest(sessionId, content),
      );
      if (disposed) return false;
      if (result[0] != true) {
        setState(() {
          draftFailure = 'Draft was not saved. Your text is preserved.';
        });
        // A newer queued edit still gets its own attempt. Never retry the same
        // failed revision automatically, including after session_busy.
        if (requestedRevision == draftRevision) {
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
    }
    draftSave = null;
    return !disposed;
  }

  Future<void> submit() async {
    if (disposed || submitting || snapshot == null) return;
    if (readSessionExecution()['canStart'] != true) return;
    if (acceptedEntry == null && controller.text.trim().isEmpty) return;
    setState(() {
      submitting = true;
      failure = '';
    });
    if (acceptedEntry == null) {
      final saved = await saveDraft();
      if (disposed) return;
      if (!saved) {
        setState(() {
          submitting = false;
        });
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
        return;
      }
      final entry = result[1] as ChatEntry;
      revision++;
      acceptedEntry = entry;
      controller.clear();
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
          maxModelInvocations: current.maxModelInvocations,
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
    }
  }

  @override
  void dispose() {
    disposed = true;
    unsubscribeSessionExecution(listener);
    controller.dispose();
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
    // flutter_eval 0.8.2 does not bridge TextField.decoration.
    children.add(Text('Ask ADELE...'));
    children.add(
      TextField(
        controller: controller,
        enabled: canSubmit && acceptedEntry == null,
        onChanged: (String value) => draftChanged(value),
        onSubmitted: (String value) => submit(),
      ),
    );
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
