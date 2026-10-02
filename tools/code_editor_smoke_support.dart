import 'dart:async';
import 'dart:io';

void validateCodeEditorSmoke(ProcessResult result) =>
    _validateCodeEditorSmokeResult(result, missingLibrary: false);

void validateCodeEditorMissingLibrary(ProcessResult result) =>
    _validateCodeEditorSmokeResult(result, missingLibrary: true);

void _validateCodeEditorSmokeResult(
  ProcessResult result, {
  required bool missingLibrary,
}) {
  final label = missingLibrary ? 'Missing-library process' : 'Profile process';
  final code = result.exitCode;
  if (code == 124) {
    throw StateError('$label timed out (exit 124).');
  }
  if (code < 0 || (code > 128 && code <= 192)) {
    final signal = code < 0 ? -code : code - 128;
    throw StateError(
      '$label terminated by signal $signal (exit $code; '
      'SIGKILL may also indicate timeout escalation).',
    );
  }
  final output = '${result.stdout}\n${result.stderr}';
  final failures = RegExp(
    r'\bCODEFORGE_[A-Z0-9_]*FAILED\b',
  ).allMatches(output).map((match) => match.group(0)!).toSet();
  if (missingLibrary) {
    if (code != 1) {
      throw StateError('$label exited $code; expected load-failure exit 1.');
    }
    if (failures.length != 1 ||
        !failures.contains('CODEFORGE_INIT_FAILED') ||
        output.contains('CODEFORGE_FRB_INIT_RETURNED') ||
        output.contains('CODEFORGE_NATIVE_INITIALIZED') ||
        output.contains('CODEFORGE_PROBE_COMPLETE')) {
      throw StateError(
        'Missing native library did not fail during FRB loading.',
      );
    }
    return;
  }
  if (failures.isNotEmpty) {
    throw StateError(
      '$label reported explicit failure: ${failures.join(', ')}.',
    );
  }
  if (code != 0) {
    throw StateError('$label exited $code.');
  }
  if (!(result.stdout as String).contains('CODEFORGE_PROBE_COMPLETE')) {
    throw StateError(
      '$label did not finish its editor checks (missing completion).',
    );
  }
}

void validateCodeEditorSmokeToolchain(
  Map<String, Object?> pin,
  Map<String, Object?> actual,
) {
  for (final entry in {
    'flutter': 'frameworkVersion',
    'flutterRevision': 'frameworkRevision',
    'engineRevision': 'engineRevision',
    'dart': 'dartSdkVersion',
  }.entries) {
    if (pin[entry.key] == null || pin[entry.key] != actual[entry.value]) {
      throw StateError('Pinned ${entry.key} mismatch: ${actual[entry.value]}');
    }
  }
}

Map<String, String> codeEditorSmokeRuntimeEnvironment(
  Map<String, String> environment,
) => Map.of(environment)
  ..remove('LD_LIBRARY_PATH')
  ..remove('LD_PRELOAD')
  ..remove('FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR')
  ..['PATH'] = '/usr/bin:/bin';

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
