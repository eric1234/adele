import 'package:adele_ui/inspection_display.dart';
import 'package:adele_ui/model_native_activity_bridge.dart';
import 'package:flutter/material.dart';

Widget buildOpenAiReasoningInspection() {
  final Map<String, dynamic> data = readModelNativeActivityData();
  final List<dynamic>? parts = _summaryParts(data);
  if (parts == null) {
    return Text('Reasoning summary unavailable.');
  }
  final List<Widget> children = <Widget>[
    Text('Reasoning summary', style: TextStyle(fontWeight: FontWeight.bold)),
  ];
  for (final dynamic part in parts) {
    children.add(SizedBox(height: 8));
    children.add(Text(inspectionDisplayText(part as String)));
  }
  if (data['truncated'] == true) {
    children.add(SizedBox(height: 8));
    children.add(Text('Reasoning summary truncated.'));
  }
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: children,
  );
}

Widget buildOpenAiReasoningCompact() {
  final Map<String, dynamic> data = readModelNativeActivityData();
  final List<dynamic>? parts = _summaryParts(data);
  if (parts == null) {
    throw FormatException('Reasoning summary unavailable.');
  }
  return Text('Reasoning: ${compactDisplayText(parts[0] as String)}');
}

List<dynamic>? _summaryParts(Map<String, dynamic> data) {
  final dynamic parts = data['summaryParts'];
  if (data.length != 2 ||
      parts is! List<dynamic> ||
      data['truncated'] is! bool) {
    return null;
  }
  if (parts.isEmpty || parts.length > 128) {
    return null;
  }
  // Validate before displaying any part. The UTF-16 ceiling accommodates the
  // projector's 32,768 Unicode code points, including supplementary characters.
  int length = 0;
  for (final dynamic part in parts) {
    if (part is! String) return null;
    length += part.length;
    if (length > 65536 || part.trim().isEmpty) {
      return null;
    }
  }
  return parts;
}
