import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Inspect the current creation draft the same way a user would, then collapse
/// its technical details again (without waiting for unrelated pending work).
Future<String> inspectDraftId(WidgetTester tester) async {
  final title = find.text('Advanced details');
  final tile = find.ancestor(of: title, matching: find.byType(ExpansionTile));
  final identity = find.descendant(
    of: tile,
    matching: find.byType(SelectableText),
  );
  Future<void> toggle() async {
    await tester.ensureVisible(title);
    await tester.tap(title);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  if (identity.evaluate().isEmpty) await toggle();
  final label = tester.widget<SelectableText>(identity).data!;
  const prefix = 'Record ID: ';
  expect(label, startsWith(prefix));
  await toggle();
  return label.substring(prefix.length);
}
