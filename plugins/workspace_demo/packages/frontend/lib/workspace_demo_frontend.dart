import 'package:flutter/material.dart';
import 'package:workspace_demo_contract/workspace_demo_contract.dart';

Future<Widget> buildWorkspaceDemo() async {
  final WorkspaceDemoViewData data = await loadWorkspaceDemoDirectory();
  final WorkspaceDemoTextData text = await loadWorkspaceDemoText(
    data.uris.first,
  );
  return Column(
    children: <Widget>[
      Text('Workspace Demo'),
      Text(data.names.join(', ')),
      Text(text.value),
    ],
  );
}
