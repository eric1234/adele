import 'dart:async';

/// One terminal path shared by the smoke body and synchronous error handlers.
class SmokeSettlement {
  SmokeSettlement({
    required this.writeOutput,
    required this.writeError,
    required this.flushOutput,
    required this.flushError,
    required this.terminate,
  });

  final void Function(String) writeOutput;
  final void Function(String) writeError;
  final Future<void> Function() flushOutput;
  final Future<void> Function() flushError;
  final void Function(int) terminate;

  ({String marker, Object error, StackTrace stack})? _failure;
  Future<void>? _settlement;

  void recordFailure(String marker, Object error, StackTrace stack) {
    _failure ??= (marker: marker, error: error, stack: stack);
  }

  Future<void> settle() => _settlement ??= Future<void>.microtask(_settle);

  Future<void> _settle() async {
    void write(void Function(String) sink, String message) {
      try {
        sink(message);
      } catch (error, stack) {
        recordFailure('CODEFORGE_SMOKE_FAILED', error, stack);
      }
    }

    Future<void> flush() async {
      for (final sink in [flushOutput, flushError]) {
        try {
          await sink();
        } catch (error, stack) {
          recordFailure('CODEFORGE_SMOKE_FAILED', error, stack);
        }
      }
    }

    await flush();
    if (_failure == null) {
      write(writeOutput, 'CODEFORGE_PROBE_COMPLETE');
      await flush();
    }
    // Completion may already be buffered when a framework/platform error arrives
    // during flush. Recheck before exiting; the driver also rejects mixed markers.
    final failure = _failure;
    if (failure != null) {
      write(writeOutput, failure.marker);
      write(
        writeError,
        '${failure.marker}: ${failure.error}\n${failure.stack}',
      );
      await flush();
    }
    terminate(_failure == null ? 0 : 1);
  }
}
