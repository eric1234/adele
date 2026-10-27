import 'package:adele_ui/rich_document_editor_bridge.dart';
import 'package:flutter/material.dart';

Widget buildView() => RichDocumentFixture('ab', false);

Future<Widget> buildHydratedView() async {
  final markdown = await hydrateMarkdown();
  final handle = createRichDocumentEditor(markdown, false);
  return RichDocumentFixture(markdown, false, handle);
}

Future<String> hydrateMarkdown() async {
  await Future<void>.delayed(Duration(milliseconds: 50));
  return 'hydrated **text**';
}

Widget buildUnsupportedView() => RichDocumentFixture(
  '![unsupported](https://example.test/image.png)',
  false,
);

Widget buildReadOnlyView() => RichDocumentFixture('read-only', true);

Widget buildFabricatedView() => buildRichDocumentEditor('fabricated');

String createHandle(String markdown, bool readOnly) =>
    createRichDocumentEditor(markdown, readOnly);

Widget buildHandle(String handle) => buildRichDocumentEditor(handle);

Map<String, dynamic> snapshotHandle(String handle) =>
    snapshotRichDocumentEditor(handle);

void observeHandle(String handle, void Function() listener) =>
    subscribeRichDocumentEditor(handle, listener);

void unobserveHandle(String handle, void Function() listener) =>
    unsubscribeRichDocumentEditor(handle, listener);

void releaseHandle(String handle) => releaseRichDocumentEditor(handle);

class RichDocumentFixture extends StatefulWidget {
  RichDocumentFixture(this.markdown, this.readOnly, [this.initialHandle = '']);

  final String markdown;
  final bool readOnly;
  final String initialHandle;

  @override
  State<RichDocumentFixture> createState() => RichDocumentFixtureState();
}

class RichDocumentFixtureState extends State<RichDocumentFixture> {
  late String handle;
  late Widget editor;
  late void Function() listener;
  String snapshotText = '(not requested)';
  String snapshotError = '';
  String snapshotReason = '';
  int snapshotRevision = -1;
  bool snapshotReadOnly = false;
  int notifications = 0;
  int rebuilds = 0;
  bool subscribed = true;
  bool visible = true;
  bool released = false;
  bool failed = false;
  bool failObserver = false;
  bool alive = true;

  @override
  void initState() {
    super.initState();
    handle = widget.initialHandle.isEmpty
        ? createRichDocumentEditor(widget.markdown, widget.readOnly)
        : widget.initialHandle;
    editor = buildRichDocumentEditor(handle);
    listener = () {
      if (!alive) return;
      if (failObserver) throw StateError('deterministic observer failure');
      setState(() {
        notifications++;
      });
    };
    subscribeRichDocumentEditor(handle, listener);
  }

  void takeSnapshot() {
    final snapshot = snapshotRichDocumentEditor(handle);
    snapshotText = snapshot['markdown'] == null
        ? '(unavailable)'
        : snapshot['markdown'] as String;
    snapshotRevision = snapshot['revision'] as int;
    snapshotReadOnly = snapshot['readOnly'] as bool;
    snapshotError = snapshot['error'] == null
        ? ''
        : snapshot['error'] as String;
    snapshotReason = snapshot['unsupportedReason'] == null
        ? ''
        : snapshot['unsupportedReason'] as String;
    setState(() {});
  }

  @override
  void dispose() {
    alive = false;
    if (!released) {
      unsubscribeRichDocumentEditor(handle, listener);
      releaseRichDocumentEditor(handle);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (failed) throw StateError('deterministic rich document fixture failure');
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
                    subscribeRichDocumentEditor(handle, listener);
                  } else {
                    unsubscribeRichDocumentEditor(handle, listener);
                  }
                });
              },
              child: Text(subscribed ? 'Unsubscribe' : 'Subscribe'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  rebuilds++;
                  editor = buildRichDocumentEditor(handle);
                });
              },
              child: Text('Rebuild'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  visible = !visible;
                });
              },
              child: Text('Toggle'),
            ),
          ],
        ),
        Row(
          children: <Widget>[
            TextButton(
              onPressed: () {
                releaseRichDocumentEditor(handle);
                setState(() {
                  released = true;
                  visible = false;
                });
              },
              child: Text('Release'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  failed = true;
                });
              },
              child: Text('Fail'),
            ),
            TextButton(
              onPressed: () {
                failObserver = true;
              },
              child: Text('Fail observer'),
            ),
          ],
        ),
        Text('Notifications: $notifications'),
        Text('Rebuilds: $rebuilds'),
        Text('Snapshot revision: $snapshotRevision'),
        Text('Snapshot readOnly: $snapshotReadOnly'),
        Text('Snapshot text: $snapshotText'),
        Text('Snapshot error: $snapshotError'),
        Text('Snapshot reason: $snapshotReason'),
        if (visible) SizedBox(height: 240, child: editor),
      ],
    );
  }
}
