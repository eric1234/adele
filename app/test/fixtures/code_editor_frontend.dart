import 'package:adele_ui/code_editor_bridge.dart';
import 'package:flutter/material.dart';

Widget buildView() => CodeEditorFixture();

Widget buildWithoutSubscription() => buildCodeEditor(requestCodeEditor());

Widget buildFabricatedView() => buildCodeEditor('fabricated');

String requestHandle() => requestCodeEditor();

Widget buildHandle(String handle) => buildCodeEditor(handle);

Map<String, dynamic> readHandle(String handle) => readCodeEditorState(handle);

Map<String, dynamic> snapshotHandle(String handle) =>
    snapshotCodeEditor(handle);

void observeHandle(String handle, void Function() listener) =>
    subscribeCodeEditor(handle, listener);

void unobserveHandle(String handle, void Function() listener) =>
    unsubscribeCodeEditor(handle, listener);

class CodeEditorFixture extends StatefulWidget {
  @override
  State<CodeEditorFixture> createState() => CodeEditorFixtureState();
}

class CodeEditorFixtureState extends State<CodeEditorFixture> {
  final String handle = requestCodeEditor();
  late Widget editor;
  late void Function() listener;
  Map<String, dynamic> state = <String, dynamic>{};
  String snapshotText = '(not requested)';
  String snapshotEscaped = '(not requested)';
  int snapshotRevision = -1;
  int notifications = 0;
  int rebuilds = 0;
  bool subscribed = true;
  bool failed = false;
  bool alive = true;

  @override
  void initState() {
    super.initState();
    // Rebuilds reuse the native editor; this evaluator does not own its text.
    editor = buildCodeEditor(handle);
    listener = () {
      if (!alive) return;
      setState(() {
        notifications++;
        state = readCodeEditorState(handle);
      });
    };
    subscribeCodeEditor(handle, listener);
    state = readCodeEditorState(handle);
  }

  void takeSnapshot() {
    try {
      state = readCodeEditorState(handle);
      if (state['ready'] != true) {
        snapshotText = '(unavailable)';
        snapshotEscaped = snapshotText;
        setState(() {});
        return;
      }
      final snapshot = snapshotCodeEditor(handle);
      if (!alive) return;
      snapshotText = snapshot['text'] as String;
      snapshotEscaped = snapshotText
          .replaceAll('\\', '\\\\')
          .replaceAll('\r', '\\r')
          .replaceAll('\n', '\\n')
          .replaceAll('\t', '\\t');
      snapshotRevision = snapshot['revision'] as int;
      state = readCodeEditorState(handle);
      setState(() {});
    } catch (error) {
      if (!alive) return;
      snapshotText = '(unavailable)';
      snapshotEscaped = snapshotText;
      setState(() {});
    }
  }

  @override
  void dispose() {
    alive = false;
    unsubscribeCodeEditor(handle, listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (failed) throw StateError('deterministic editor fixture failure');
    final revision = state['revision'];
    final ready = state['ready'];
    final readOnly = state['readOnly'];
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            TextButton(onPressed: takeSnapshot, child: Text('Snapshot')),
            TextButton(
              onPressed: () {
                setState(() {
                  subscribed = !subscribed;
                  if (subscribed) {
                    subscribeCodeEditor(handle, listener);
                    state = readCodeEditorState(handle);
                  } else {
                    unsubscribeCodeEditor(handle, listener);
                  }
                });
              },
              child: Text(subscribed ? 'Unsubscribe' : 'Subscribe'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  rebuilds++;
                });
              },
              child: Text('Rebuild'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  failed = true;
                });
              },
              child: Text('Fail'),
            ),
          ],
        ),
        Text('State: $revision ready=$ready readOnly=$readOnly'),
        Text('Notifications: $notifications'),
        Text('Rebuilds: $rebuilds'),
        Text('Snapshot revision: $snapshotRevision'),
        Text('Snapshot text: $snapshotText'),
        Text('Snapshot escaped: $snapshotEscaped'),
        SizedBox(height: 240, child: editor),
      ],
    );
  }
}
