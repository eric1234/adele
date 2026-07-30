import 'package:flutter/material.dart';

import 'src/adele_eval_bridge.dart';

Future<Widget> buildWorkspaceDemo() async {
  final WorkspaceDemoViewData data = await loadWorkspaceDemoDirectory();
  if (data.cancelled) return SizedBox.shrink();
  return WorkspaceDemoWidget(data: data);
}

class WorkspaceDemoWidget extends StatefulWidget {
  WorkspaceDemoWidget({required this.data});

  final WorkspaceDemoViewData data;

  @override
  State<WorkspaceDemoWidget> createState() => _WorkspaceDemoWidgetState();
}

class _WorkspaceDemoWidgetState extends State<WorkspaceDemoWidget> {
  int selectedIndex = -1;
  WorkspaceDemoTextData selectedText = WorkspaceDemoTextData('');
  bool hasSelectedText = false;
  bool disposed = false;

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }

  Future<void> selectFile(int index) async {
    final WorkspaceDemoTextData text = await loadWorkspaceDemoText(
      widget.data.uris[index],
    );
    if (disposed || text.cancelled) return;
    setState(() {
      selectedIndex = index;
      selectedText = text;
      hasSelectedText = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> children = <Widget>[Text('Workspace Demo')];
    if (widget.data.names.isNotEmpty) {
      children.add(
        TextButton(
          onPressed: () => selectFile(0),
          child: Text(widget.data.names[0]),
        ),
      );
    }
    if (widget.data.names.length > 1) {
      children.add(
        TextButton(
          onPressed: () => selectFile(1),
          child: Text(widget.data.names[1]),
        ),
      );
    }
    if (selectedIndex >= 0 && hasSelectedText) {
      children.add(Text('Selected: ${widget.data.names[selectedIndex]}'));
      children.add(Text(selectedText.value));
    }
    return Column(children: children);
  }
}
