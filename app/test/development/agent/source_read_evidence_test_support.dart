import 'dart:convert';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';

/// Checks read evidence against the complete, pre-patch source, not patch text.
void expectSourceReadEvidence({
  required Map<String, Object?> arguments,
  required ToolOutcome outcome,
  required String originalText,
  required String relativePath,
  required String revision,
}) {
  expect(revision, isNotEmpty);
  expect(outcome.hostData['revision'], revision);
  expect(outcome.hostData['sizeBytes'], utf8.encode(originalText).length);
  String selectedText = originalText;
  String metadata = '';
  const List<String> rangeKeys = <String>[
    'startLine',
    'requestedLineCount',
    'returnedLineCount',
    'totalLines',
    'nextStartLine',
  ];
  if (arguments.containsKey('startLine') ||
      arguments.containsKey('lineCount')) {
    final int start = arguments['startLine'] as int? ?? 1;
    final int? count = arguments['lineCount'] as int?;
    expect(start, greaterThan(0));
    if (count != null) expect(count, greaterThan(0));
    // Keep terminators in each match: CRLF is one boundary, and a final
    // terminator does not introduce a phantom empty line.
    final List<String> lines = RegExp(r'[^\r\n]*(?:\r\n|\r|\n|$)')
        .allMatches(originalText)
        .map((Match match) => match.group(0)!)
        .where((String line) => line.isNotEmpty)
        .toList();
    final Iterable<String> remaining = lines.skip(start - 1);
    final List<String> selected =
        (count == null ? remaining : remaining.take(count)).toList();
    selectedText = selected.join();
    final int? next =
        count != null &&
            selected.isNotEmpty &&
            start - 1 + selected.length < lines.length
        ? start + selected.length
        : null;
    final Map<String, Object?> expectedRange = <String, Object?>{
      'startLine': start,
      'requestedLineCount': count,
      'returnedLineCount': selected.length,
      'totalLines': lines.length,
      'nextStartLine': next,
    };
    for (final String key in rangeKeys) {
      expect(outcome.hostData.containsKey(key), isTrue, reason: key);
      expect(outcome.hostData[key], expectedRange[key], reason: key);
    }
    metadata = selected.isEmpty
        ? 'Lines: empty selection at line $start of ${lines.length} (0 returned)\n'
        : 'Lines: $start-${start + selected.length - 1} of ${lines.length}\n';
    if (next != null) {
      metadata +=
          'Next read: ${jsonEncode(<String, Object?>{'relativePath': relativePath, 'startLine': next, 'lineCount': count})}\n';
    }
  } else {
    for (final String key in rangeKeys) {
      expect(outcome.hostData.containsKey(key), isFalse, reason: key);
    }
  }
  expect(outcome.hostData['text'], selectedText);
  expect(
    outcome.modelContent,
    'File: ${jsonEncode(relativePath)}\n'
    'Revision: ${jsonEncode(revision)}\n'
    '$metadata\n$selectedText',
  );
}
