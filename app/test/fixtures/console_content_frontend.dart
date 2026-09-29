import 'package:adele_ui/console_bridge.dart';
import 'package:flutter/material.dart';

Future<List<dynamic>> open() => openPreparedConsole(
  'test.read-only',
  'run/invocation',
  'Read-only output',
  {'identity': 'opaque'},
);

Widget buildContent() {
  final data = readConsoleContentData();
  final state = readConsoleContentState();
  int history = 0;
  if (state['history'] != null) history = state['history'] as int;
  final nextHistory = history + 1;
  return TextButton(
    onPressed: () {
      writeConsoleContentState({'history': nextHistory, 'following': false});
    },
    child: Text('Identity: ${data['identity']}; history: $history'),
  );
}
