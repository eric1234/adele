import 'dart:convert';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'source_read_evidence_test_support.dart';

const String _path = 'source.dart';
const String _revision = 'opaque whole-file revision';
const String _source = 'first\r\n  café\nthird\rlast';

void main() {
  final List<
    ({
      String name,
      Map<String, Object?> arguments,
      String text,
      String metadata,
      Map<String, Object?> range,
    })
  >
  cases = [
    (name: 'whole file', arguments: {}, text: _source, metadata: '', range: {}),
    (
      name: 'startLine 1 with all source',
      arguments: {'startLine': 1},
      text: _source,
      metadata: 'Lines: 1-4 of 4\n',
      range: {
        'startLine': 1,
        'requestedLineCount': null,
        'returnedLineCount': 4,
        'totalLines': 4,
        'nextStartLine': null,
      },
    ),
    (
      name: 'interior finite reread',
      arguments: {'startLine': 2, 'lineCount': 2},
      text: '  café\nthird\r',
      metadata:
          'Lines: 2-3 of 4\nNext read: {"relativePath":"source.dart","startLine":4,"lineCount":2}\n',
      range: {
        'startLine': 2,
        'requestedLineCount': 2,
        'returnedLineCount': 2,
        'totalLines': 4,
        'nextStartLine': 4,
      },
    ),
  ];
  for (final selection in cases) {
    ToolOutcome outcome({
      Map<String, Object?> overrides = const {},
      String? modelContent,
    }) => ToolOutcome(
      disposition: ToolOutcomeDisposition.success,
      effectCertainty: EffectCertainty.knownOccurred,
      modelContent:
          modelContent ??
          'File: "source.dart"\nRevision: "opaque whole-file revision"\n${selection.metadata}\n${selection.text}',
      hostData: {
        'relativePath': _path,
        'revision': _revision,
        'sizeBytes': utf8.encode(_source).length,
        'text': selection.text,
        ...selection.range,
        ...overrides,
      },
    );
    void check(ToolOutcome value) => expectSourceReadEvidence(
      arguments: {'relativePath': _path, ...selection.arguments},
      outcome: value,
      originalText: _source,
      relativePath: _path,
      revision: _revision,
    );
    test('accepts ${selection.name} before patch of complete source', () {
      // A focused reread retains the same opaque revision as the whole read.
      // The consumer receives the last matching read, not necessarily all text.
      check(outcome());
    });
    test('rejects corrupt ${selection.name} evidence', () {
      for (final bad in <Map<String, Object?>>[
        {'revision': 'other revision'},
        {'sizeBytes': 1},
        {'text': 'wrong'},
        if (selection.range.isNotEmpty) {'totalLines': 99},
        if (selection.range.isNotEmpty) {'returnedLineCount': 99},
        if (selection.range.isNotEmpty) {'nextStartLine': 99},
      ]) {
        expect(
          () => check(outcome(overrides: bad)),
          throwsA(isA<TestFailure>()),
        );
      }
      expect(
        () => check(outcome(modelContent: 'wrong')),
        throwsA(isA<TestFailure>()),
      );
    });
  }
}
