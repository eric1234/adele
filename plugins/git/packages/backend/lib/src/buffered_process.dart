part of 'foreground_process.dart';

const Duration _bufferedCleanupDeadline = Duration(seconds: 1);

/// Internal startup seam for testing ownership of late native starts.
typedef GitBufferedProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      required String workingDirectory,
      required Map<String, String> environment,
    });

Future<Process> _startBufferedProcess(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required Map<String, String> environment,
}) => Process.start(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: environment,
  includeParentEnvironment: false,
  runInShell: false,
  mode: ProcessStartMode.normal,
);

final class GitBufferedProcessSupervisor {
  GitBufferedProcessSupervisor({GitBufferedProcessStarter? startProcess})
    : _startProcess = startProcess ?? _startBufferedProcess;

  final GitBufferedProcessStarter _startProcess;
  final Set<_BufferedProcessExecution> _active = <_BufferedProcessExecution>{};
  bool _closing = false;
  Future<void>? _closeFuture;

  /// Includes pending starts and cleanup, even after their caller has failed.
  int get activeExecutionCount => _active.length;

  int get retainedOutputBytes => _active.fold(
    0,
    (total, execution) =>
        total + execution._stdout.length + execution._stderr.length,
  );

  Future<EnvironmentBufferedProcessResult> run({
    required EnvironmentId environmentId,
    required WorktreeEnvironment environment,
    required EnvironmentBufferedProcessRequest request,
  }) {
    if (_closing) {
      return Future<EnvironmentBufferedProcessResult>.error(
        const EnvironmentFailure(
          code: 'process_provider_closed',
          message: 'The Environment provider is shutting down.',
          details: <String, Object?>{},
        ),
      );
    }
    final execution = _BufferedProcessExecution(
      this,
      environmentId,
      environment,
      request,
    );
    _active.add(execution);
    return execution.run();
  }

  Future<void> close() {
    _closing = true;
    return _closeFuture ??= Future.wait<void>(
      _active.toList(growable: false).map((execution) => execution.close()),
    );
  }
}

final class _BufferedProcessExecution {
  _BufferedProcessExecution(
    this.owner,
    this.environmentId,
    this.environment,
    this.request,
  );

  final GitBufferedProcessSupervisor owner;
  final EnvironmentId environmentId;
  final WorktreeEnvironment environment;
  final EnvironmentBufferedProcessRequest request;
  final Completer<EnvironmentBufferedProcessResult> _result =
      Completer<EnvironmentBufferedProcessResult>();
  final Completer<void> _interrupted = Completer<void>();
  final Completer<bool> _finished = Completer<bool>();
  final Stopwatch _watch = Stopwatch();
  final BytesBuilder _stdout = BytesBuilder();
  final BytesBuilder _stderr = BytesBuilder();
  final List<StreamSubscription<List<int>>> _subscriptions = [];
  Timer? _deadline;
  EnvironmentFailure? _failure;
  Process? _process;
  Future<void>? _stdinDone;
  Future<int>? _exitCode;
  Future<void>? _termination;
  Future<void>? _cleanup;
  bool _leaderExited = false;
  bool _starting = false;

  Future<EnvironmentBufferedProcessResult> run() {
    _watch.start();
    _deadline = Timer(Duration(seconds: request.timeoutSeconds), _timeOut);
    unawaited(_execute());
    return _result.future;
  }

  void _timeOut() => _abort(
    _error('process_timed_out', 'The buffered process deadline expired.'),
  );

  void _requireLive() {
    // Async callbacks and synchronous encoding can outrun the timer event.
    if (_watch.elapsed >= Duration(seconds: request.timeoutSeconds)) _timeOut();
    if (_failure case final failure?) throw failure;
  }

  Future<void> close() async {
    _abort(
      _error(
        'process_provider_closed',
        'The Environment provider is shutting down.',
      ),
    );
    try {
      if (await _finished.future.timeout(_bufferedCleanupDeadline)) return;
    } on TimeoutException {
      // Do not release a pending start: _execute still owns its late result.
    }
    throw _error(
      'process_cleanup_failed',
      'Buffered process startup or cleanup did not settle during shutdown.',
    );
  }

  Future<void> _execute() async {
    try {
      _requireSupportedPlatform();
      _requireLive();
      final workingDirectory = await environment.resolveProcessWorkingDirectory(
        request.relativeWorkingDirectory,
      );
      _requireLive();
      final childEnvironment = _childEnvironment(workingDirectory);
      final executable = await _resolveExecutable(
        request.program,
        workingDirectory,
        childEnvironment['PATH']!,
      );
      _requireLive();
      final launcher = await _resolveSetSid();
      _requireLive();
      final revalidated = await environment.resolveProcessWorkingDirectory(
        request.relativeWorkingDirectory,
      );
      if (revalidated.path != workingDirectory.path) {
        throw _error(
          'process_working_directory_changed',
          'The process working directory changed while it was being resolved.',
        );
      }
      final input = decodeEnvironmentProcessBytes(
        request.stdinBase64,
        maximumBytes: environmentBufferedProcessStdinLimit,
      );
      _requireLive();
      final Process process;
      _starting = true;
      try {
        process = await owner._startProcess(
          launcher,
          ['--', executable, ...request.arguments],
          workingDirectory: revalidated.path,
          environment: childEnvironment,
        );
      } on ProcessException {
        throw _error(
          'process_start_failed',
          'The buffered process could not be started.',
        );
      } finally {
        _starting = false;
      }
      // A timeout/shutdown can win Process.start. Attach ownership before any
      // liveness check so its eventual resource is always drained and killed.
      _process = process;
      _exitCode = process.exitCode.then((code) {
        _leaderExited = true;
        return code;
      });
      final exited = _observe(
        _exitCode!.then((_) => _terminateProcessGroup()),
        'process_execution_failed',
      );
      final stdoutDone = _collect(
        process.stdout,
        _stdout,
        environmentBufferedProcessStdoutLimit,
        'stdout',
      );
      final stderrDone = _collect(
        process.stderr,
        _stderr,
        environmentBufferedProcessStderrLimit,
        'stderr',
      );
      // Observe sink errors immediately, not only after awaiting flush/close.
      _stdinDone = _observe(process.stdin.done, 'process_stdin_failed');
      final inputDone = _observe(
        _writeInput(process, _failure == null ? input : const []),
        'process_stdin_failed',
      );
      await Future.any<void>([
        Future.wait<void>([exited, stdoutDone, stderrDone, inputDone]),
        _interrupted.future,
      ]);
      _requireLive();
      await Future.any<void>([_cleanUp(), _interrupted.future]);
      _requireLive();
      final result = EnvironmentBufferedProcessResult(
        exitCode: await _exitCode!,
        stdoutBase64: encodeEnvironmentProcessBytes(
          _stdout.takeBytes(),
          maximumBytes: environmentBufferedProcessStdoutLimit,
        ),
        stderrBase64: encodeEnvironmentProcessBytes(
          _stderr.takeBytes(),
          maximumBytes: environmentBufferedProcessStderrLimit,
        ),
      );
      _requireLive();
      _deadline?.cancel();
      _result.complete(result);
    } on Object catch (error) {
      _abort(
        error is EnvironmentFailure
            ? error
            : _error(
                'process_execution_failed',
                'The buffered process execution failed.',
              ),
      );
    } finally {
      _deadline?.cancel();
      var cleaned = false;
      try {
        // This continuation deliberately outlives bounded caller settlement.
        // An unresolved start or native cleanup remains in the owner's set.
        await _cleanUp();
        cleaned = true;
        owner._active.remove(this);
      } on Object {
        _abort(_error('process_cleanup_failed', 'Process cleanup failed.'));
      }
      _finished.complete(cleaned);
    }
  }

  Future<void> _writeInput(Process process, List<int> input) async {
    var consumed = input.isEmpty;
    Stream<List<int>> bytes() async* {
      if (input.isNotEmpty) yield input;
      consumed = true;
    }

    // Dart destroys the stdin socket on process exit, which can resolve a
    // pending addStream/flush without a write error. Its paused source is then
    // cancelled: resumption past yield, not flush alone, proves full admission.
    try {
      await process.stdin.addStream(bytes());
      if (!consumed) {
        throw _error(
          'process_stdin_failed',
          'The process did not accept all input.',
        );
      }
      await process.stdin.flush();
    } finally {
      await process.stdin.close();
    }
    await _stdinDone;
  }

  Future<void> _observe(Future<dynamic> future, String code) async {
    try {
      await future;
    } on Object {
      _abort(_error(code, 'Buffered process I/O did not complete.'));
    }
  }

  Future<void> _collect(
    Stream<List<int>> source,
    BytesBuilder buffer,
    int limit,
    String pipe,
  ) {
    final done = Completer<void>();
    _subscriptions.add(
      source.listen(
        (bytes) {
          if (_failure != null) return;
          // Do not retain even a view of an oversized SDK read. BytesBuilder's
          // copying mode owns only admitted bytes, not a larger backing buffer.
          if (bytes.length > limit - buffer.length) {
            _abort(
              _error(
                'process_output_overflow',
                'The buffered process output exceeded its byte limit.',
                details: {'stream': pipe, 'maximumBytes': limit},
              ),
            );
            return;
          }
          buffer.add(bytes);
        },
        onDone: done.complete,
        onError: (Object _, StackTrace _) {
          _abort(
            _error('process_output_failed', 'The process output read failed.'),
          );
          done.complete();
        },
        cancelOnError: true,
      ),
    );
    return done.future;
  }

  void _abort(EnvironmentFailure failure) {
    if (_failure != null || _result.isCompleted) return;
    _failure = failure;
    _deadline?.cancel();
    _stdout.clear();
    _stderr.clear();
    _interrupted.complete();
    unawaited(_failAfterCleanup());
  }

  Future<void> _failAfterCleanup() async {
    var cleanupIncomplete = _starting;
    try {
      await _cleanUp().timeout(_bufferedCleanupDeadline);
    } on Object {
      cleanupIncomplete = true;
    }
    if (_result.isCompleted) return;
    final failure = _failure!;
    _result.completeError(
      cleanupIncomplete
          ? _error(
              failure.code,
              failure.message,
              details: {...failure.details, 'cleanupIncomplete': true},
            )
          : failure,
    );
  }

  Future<void> _cleanUp() {
    final process = _process;
    // Never memoize absence: Process.start may still return an owned resource.
    if (process == null) return Future<void>.value();
    return _cleanup ??= Future.wait<void>([
      _terminateProcessGroup(),
      for (final subscription in _subscriptions) subscription.cancel(),
      () async {
        try {
          await process.stdin.close();
        } on Object {
          // Input failure already prevents success; still join sink settlement.
        }
        await _stdinDone;
      }(),
    ]);
  }

  Future<void> _terminateProcessGroup() {
    final process = _process!;
    return _termination ??= () async {
      final leaderWasRunning = !_leaderExited;
      final groupFound = _killProcessGroup(process.pid, ProcessSignal.sigterm);
      if (!groupFound && !_leaderExited) {
        _killProcess(process.pid, ProcessSignal.sigterm);
      }
      if (leaderWasRunning || groupFound) {
        await Future<void>.delayed(_processTerminationGrace);
        _killProcessGroup(process.pid, ProcessSignal.sigkill);
        if (!_leaderExited) _killProcess(process.pid, ProcessSignal.sigkill);
      }
      await _exitCode;
    }();
  }

  EnvironmentFailure _error(
    String code,
    String message, {
    Map<String, Object?> details = const {},
  }) => EnvironmentFailure(
    code: code,
    message: message,
    details: {'environmentId': environmentId.value, ...details},
  );
}
