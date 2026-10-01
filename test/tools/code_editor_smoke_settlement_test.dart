import 'dart:async';

import 'package:test/test.dart';

import '../../tools/code_editor_probe/smoke_settlement.dart';

void main() {
  late SmokeSettlement settlement;
  late List<String> output;
  late List<String> errors;
  late List<int> exits;
  late Future<void> Function() flushOutput;
  late Future<void> Function() flushError;

  setUp(() {
    output = [];
    errors = [];
    exits = [];
    flushOutput = () async {};
    flushError = () async {};
    settlement = SmokeSettlement(
      writeOutput: output.add,
      writeError: errors.add,
      flushOutput: () => flushOutput(),
      flushError: () => flushError(),
      terminate: exits.add,
    );
  });

  test('normal completion settles once, including repeated callers', () async {
    final done = settlement.settle();
    expect(settlement.settle(), same(done));
    await done;
    expect(settlement.settle(), same(done));
    expect(output, ['CODEFORGE_PROBE_COMPLETE']);
    expect(errors, isEmpty);
    expect(exits, [0]);
  });

  test(
    'synchronous error recording beats a pending success settlement',
    () async {
      final done = settlement.settle();
      settlement.recordFailure(
        'CODEFORGE_SMOKE_FAILED',
        StateError('framework error'),
        StackTrace.fromString('framework stack'),
      );
      expect(settlement.settle(), same(done));
      await done;
      expect(output, ['CODEFORGE_SMOKE_FAILED']);
      expect(errors, [
        'CODEFORGE_SMOKE_FAILED: Bad state: framework error\nframework stack',
      ]);
      expect(exits, [1]);
    },
  );

  test('init failure retains first marker, error and stack', () async {
    settlement.recordFailure(
      'CODEFORGE_INIT_FAILED',
      StateError('missing library'),
      StackTrace.fromString('init stack'),
    );
    settlement.recordFailure(
      'CODEFORGE_SMOKE_FAILED',
      StateError('secondary platform error'),
      StackTrace.fromString('secondary stack'),
    );
    await settlement.settle();
    expect(output, ['CODEFORGE_INIT_FAILED']);
    expect(errors, [
      'CODEFORGE_INIT_FAILED: Bad state: missing library\ninit stack',
    ]);
    expect(exits, [1]);
  });

  for (final stream in ['stdout', 'stderr']) {
    for (final flushNumber in [1, 2]) {
      test(
        '$stream error during flush $flushNumber cannot exit successfully',
        () async {
          final flushing = Completer<void>();
          final release = Completer<void>();
          var count = 0;
          Future<void> flush() {
            if (++count == flushNumber) {
              flushing.complete();
              return release.future;
            }
            return Future<void>.value();
          }

          if (stream == 'stdout') {
            flushOutput = flush;
          } else {
            flushError = flush;
          }
          final done = settlement.settle();
          await flushing.future;
          // The same synchronous record-and-settle path used by both callbacks.
          final source = stream == 'stdout' ? 'framework' : 'platform';
          settlement.recordFailure(
            'CODEFORGE_SMOKE_FAILED',
            StateError('$source error'),
            StackTrace.fromString('$source stack'),
          );
          expect(settlement.settle(), same(done));
          expect(exits, isEmpty);
          release.complete();
          await done;
          expect(output, [
            if (flushNumber == 2) 'CODEFORGE_PROBE_COMPLETE',
            'CODEFORGE_SMOKE_FAILED',
          ]);
          expect(errors, [
            'CODEFORGE_SMOKE_FAILED: Bad state: $source error\n$source stack',
          ]);
          expect(exits, [1]);
        },
      );
    }
  }

  test(
    'late platform error and flush error preserve the first diagnostic',
    () async {
      settlement.recordFailure(
        'CODEFORGE_SMOKE_FAILED',
        StateError('first framework error'),
        StackTrace.fromString('first stack'),
      );
      final flushing = Completer<void>();
      final release = Completer<void>();
      var count = 0;
      flushError = () {
        if (++count == 2) {
          flushing.complete();
          return release.future;
        }
        return Future<void>.value();
      };
      final done = settlement.settle();
      await flushing.future;
      settlement.recordFailure(
        'CODEFORGE_SMOKE_FAILED',
        StateError('late platform error'),
        StackTrace.fromString('late stack'),
      );
      expect(settlement.settle(), same(done));
      release.completeError(StateError('flush error'));
      await done;
      expect(output, ['CODEFORGE_SMOKE_FAILED']);
      expect(errors, [
        'CODEFORGE_SMOKE_FAILED: Bad state: first framework error\nfirst stack',
      ]);
      expect(exits, [1]);
    },
  );

  for (final stream in ['stdout', 'stderr']) {
    test('$stream flush exception is a terminal failure', () async {
      Future<void> failFlush() async => throw StateError('flush error');
      if (stream == 'stdout') {
        flushOutput = failFlush;
      } else {
        flushError = failFlush;
      }
      await settlement.settle();
      expect(output, ['CODEFORGE_SMOKE_FAILED']);
      expect(errors.single, contains('Bad state: flush error'));
      expect(exits, [1]);
    });
  }
}
