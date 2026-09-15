import 'package:adele_ui/inspection_display.dart';
import 'package:adele_ui/model_native_activity_bridge.dart';
import 'package:flutter/material.dart';

Widget buildOpenAiReasoningInspection() {
  final Map<String, dynamic> data = readModelNativeActivityData();
  final dynamic parts = data['summaryParts'];
  final dynamic truncated = data['truncated'];
  if (data.length != 2 || parts is! List<dynamic> || truncated is! bool) {
    return Text('Reasoning summary unavailable.');
  }
  if (parts.isEmpty || parts.length > 128) {
    return Text('Reasoning summary unavailable.');
  }
  // Validate before displaying any part. The UTF-16 ceiling accommodates the
  // projector's 32,768 Unicode code points, including supplementary characters.
  int length = 0;
  for (final dynamic part in parts) {
    if (part is! String) return Text('Reasoning summary unavailable.');
    length += part.length;
    if (length > 65536 || part.trim().isEmpty) {
      return Text('Reasoning summary unavailable.');
    }
  }
  final List<Widget> children = <Widget>[
    Text('Reasoning summary', style: TextStyle(fontWeight: FontWeight.bold)),
  ];
  for (final dynamic part in parts) {
    children.add(SizedBox(height: 8));
    children.add(Text(inspectionDisplayText(part as String)));
  }
  if (truncated) {
    children.add(SizedBox(height: 8));
    children.add(Text('Reasoning summary truncated.'));
  }
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: children,
  );
}
