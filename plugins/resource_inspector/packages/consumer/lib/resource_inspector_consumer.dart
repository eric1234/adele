import 'package:flutter/material.dart';

import 'src/adele_eval_bridge.dart';

Future<Widget> buildCapabilityDemo() async {
  final CapabilityDemoData data = await loadCapabilityDemo();
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text('Resource Inspector Capability'),
      for (final String line in data.lines) Text(line),
    ],
  );
}
