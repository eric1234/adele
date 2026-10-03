import 'package:adele_ui/code_editor_bridge.dart';
import 'package:adele_ui/main_content_bridge.dart';
import 'package:flutter/material.dart';

void initialize() {
  openMainContentPane('editor-a', 'Editor A', false);
}

Widget buildPane() => MainContentEditorFixture();

class MainContentEditorFixture extends StatefulWidget {
  @override
  State<MainContentEditorFixture> createState() => MainContentEditorState();
}

class MainContentEditorState extends State<MainContentEditorFixture> {
  final String paneId = readMainContentPaneId();
  late Widget editor;

  @override
  void initState() {
    super.initState();
    editor = buildCodeEditor(requestCodeEditor());
  }

  void reverseEditors() {
    final panes = readMainContentPanes();
    final ids = <String>[];
    for (var index = panes.length - 1; index >= 0; index--) {
      ids.add(panes[index]['id'] as String);
    }
    setMainContentPaneOrder(ids);
  }

  bool hasB() {
    for (final pane in readMainContentPanes()) {
      if (pane['id'] == 'editor-b') return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Text('Synthetic pane: $paneId'),
      if (paneId == 'editor-a')
        Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                TextButton(
                  onPressed: () {
                    if (hasB()) {
                      focusMainContentPane('editor-b', true);
                    } else {
                      openMainContentPane('editor-b', 'Editor B', true);
                    }
                  },
                  child: Text('Open B'),
                ),
                TextButton(
                  onPressed: () {
                    if (hasB()) {
                      setMainContentPaneTitle('editor-b', 'Renamed B');
                    }
                  },
                  child: Text('Rename B'),
                ),
              ],
            ),
            Row(
              children: <Widget>[
                TextButton(
                  onPressed: () {
                    focusMainContentPane('editor-a', true);
                  },
                  child: Text('Focus A'),
                ),
                TextButton(
                  onPressed: () {
                    if (hasB()) focusMainContentPane('editor-b', true);
                  },
                  child: Text('Focus B'),
                ),
              ],
            ),
            Row(
              children: <Widget>[
                TextButton(
                  onPressed: reverseEditors,
                  child: Text('Reverse editors'),
                ),
                TextButton(
                  onPressed: () {
                    removeMainContentPane('editor-b');
                  },
                  child: Text('Remove B'),
                ),
              ],
            ),
          ],
        ),
      Expanded(flex: 1, child: editor),
    ],
  );
}
