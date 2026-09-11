import 'dart:convert';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'source_coding_live_test_support.dart';
import 'source_read_evidence_test_support.dart';

const String _path = 'source.dart';
const String _revision = 'opaque whole-file revision';
const String _source = 'first\r\n  café\nthird\rlast';
const String _fragment = 'third';

void main() {
  final List<
    ({
      String name,
      Map<String, Object?> arguments,
      String text,
      String metadata,
      Map<String, Object?> range,
      bool observesFragment,
    })
  >
  cases = [
    (
      name: 'whole file',
      arguments: {},
      text: _source,
      metadata: '',
      range: {},
      observesFragment: true,
    ),
    (
      name: 'startLine 1 with all source',
      observesFragment: true,
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
      observesFragment: true,
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
    (
      name: 'unrelated range',
      observesFragment: false,
      arguments: {'startLine': 1, 'lineCount': 1},
      text: 'first\r\n',
      metadata:
          'Lines: 1-1 of 4\nNext read: {"relativePath":"source.dart","startLine":2,"lineCount":1}\n',
      range: {
        'startLine': 1,
        'requestedLineCount': 1,
        'returnedLineCount': 1,
        'totalLines': 4,
        'nextStartLine': 2,
      },
    ),
    (
      name: 'out-of-range empty selection',
      observesFragment: false,
      arguments: {'startLine': 10, 'lineCount': 1},
      text: '',
      metadata: 'Lines: empty selection at line 10 of 4 (0 returned)\n',
      range: {
        'startLine': 10,
        'requestedLineCount': 1,
        'returnedLineCount': 0,
        'totalLines': 4,
        'nextStartLine': null,
      },
    ),
  ];
  final Map<String, SourceCodingToolAttempt> reads = {};
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
    final SourceCodingToolAttempt read = _readAttempt(
      arguments: {'relativePath': _path, ...selection.arguments},
      outcome: outcome(),
      sequence: reads.length * 2,
    );
    reads[selection.name] = read;
    test('accepts accurate ${selection.name} envelope', () {
      check(outcome());
    });
    test('checks target observation for ${selection.name}', () {
      SourceCodingToolAttempt relevantRead() => expectRelevantSourceRead(
        reads: [read],
        beforeSequence: 20,
        relativePath: _path,
        revision: _revision,
        originalFragment: _fragment,
      );
      if (selection.observesFragment) {
        expect(relevantRead(), same(read));
      } else {
        expect(relevantRead, throwsA(isA<TestFailure>()));
      }
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
  test(
    'earlier target observation survives later unrelated or empty reads',
    () {
      final SourceCodingToolAttempt observed = reads['interior finite reread']!;
      expect(
        expectRelevantSourceRead(
          reads: [
            observed,
            reads['unrelated range']!,
            reads['out-of-range empty selection']!,
          ],
          beforeSequence: 20,
          relativePath: _path,
          revision: _revision,
          originalFragment: _fragment,
        ),
        same(observed),
      );
    },
  );
  test('target observation requires matching path, revision and ordering', () {
    final SourceCodingToolAttempt read = reads['interior finite reread']!;
    for (final criteria in [
      (path: 'other.dart', revision: _revision, before: 20),
      (path: _path, revision: 'other revision', before: 20),
      (path: _path, revision: _revision, before: read.terminalRecord.sequence),
      (path: _path, revision: _revision, before: read.preparedRecord.sequence),
    ]) {
      expect(
        () => expectRelevantSourceRead(
          reads: [read],
          beforeSequence: criteria.before,
          relativePath: criteria.path,
          revision: criteria.revision,
          originalFragment: _fragment,
        ),
        throwsA(isA<TestFailure>()),
      );
    }
  });
  test('failed reads cannot provide target observation', () {
    final SourceCodingToolAttempt read = reads['interior finite reread']!;
    final SourceCodingToolAttempt failed = _readAttempt(
      arguments: read.prepared.invocation.canonicalArguments,
      outcome: ToolOutcome(
        disposition: ToolOutcomeDisposition.failure,
        failureKind: ToolFailureKind.domain,
        effectCertainty: EffectCertainty.knownNotOccurred,
        modelContent: read.outcome.modelContent,
        hostData: read.outcome.hostData,
      ),
    );
    expect(
      () => expectRelevantSourceRead(
        reads: [failed],
        beforeSequence: 20,
        relativePath: _path,
        revision: _revision,
        originalFragment: _fragment,
      ),
      throwsA(isA<TestFailure>()),
    );
  });
}

SourceCodingToolAttempt _readAttempt({
  required Map<String, Object?> arguments,
  required ToolOutcome outcome,
  int sequence = 0,
}) {
  final ResolvedToolProposal resolved =
      const ToolInvocationResolver().resolve(
            invocationId: ToolInvocationId('read-$sequence'),
            proposal: ProviderToolProposal(
              providerCallId: 'read-$sequence',
              alias: 'read_file',
              arguments: arguments,
            ),
            tools: MaterializedToolSet([
              MaterializedTool(
                definition: ToolDefinition(
                  id: ToolId('read'),
                  description: 'Read',
                ),
                modelDefinition: ModelToolDefinition(
                  alias: 'read_file',
                  description: 'Read',
                  argumentsSchema: const {},
                ),
                executable: _ReadExecutable(),
              ),
            ]),
            context: ToolExecutionContext(
              runId: RunId('read-evidence'),
              sessionId: SessionId('read-evidence'),
            ),
          )
          as ResolvedToolProposal;
  return SourceCodingToolAttempt(
    preparedRecord: ExecutionEventRecord(
      sequence: sequence,
      event: ToolInvocationPrepared(resolved.invocation),
    ),
    terminalRecord: ExecutionEventRecord(
      sequence: sequence + 1,
      event: ToolExecutionCompleted(
        invocationId: resolved.invocation.id,
        outcome: outcome,
      ),
    ),
  );
}

final class _ReadExecutable extends Fake implements ToolExecutable {
  @override
  CanonicalToolArguments validateAndNormalize(Map<String, Object?> arguments) =>
      CanonicalToolArguments(arguments);

  @override
  void validateBinding() {}
}
