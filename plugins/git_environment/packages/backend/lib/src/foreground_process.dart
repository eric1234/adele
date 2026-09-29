import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';

import 'worktree_environment.dart';

// The pinned Dart Process pipe stream aggregates up to 4 MiB plus one native
// read. This bounds full decoded Strings owned by our queue across both pipes,
// not SDK byte/conversion buffers or emitted message copies. Two maximum SDK
// reads need not fit; excess decoded admission fails rather than being queued.
const int _maximumPendingOutputCharacters = 8 * 1024 * 1024;
const Duration _processTerminationGrace = Duration(milliseconds: 250);
const Duration _processPipeCloseGrace = Duration(seconds: 1);
const Duration _processMaximumDrain = Duration(seconds: 10);
const int _atCurrentWorkingDirectory = -100;
const int _executeAccess = 1;
const int _atEffectiveAccess = 0x200;

typedef _FaccessatNative = Int32 Function(Int32, Pointer<Uint8>, Int32, Int32);
typedef _FaccessatDart = int Function(int, Pointer<Uint8>, int, int);
typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

const Set<String> _retainedEnvironmentVariables = <String>{
  'HOME',
  'LANG',
  'LANGUAGE',
  'LOGNAME',
  'PATH',
  'SHELL',
  'TEMP',
  'TMP',
  'TMPDIR',
  'TZ',
  'USER',
  'XDG_CACHE_HOME',
  'XDG_CONFIG_HOME',
  'XDG_DATA_DIRS',
  'XDG_DATA_HOME',
  'XDG_RUNTIME_DIR',
};

final class GitForegroundProcessSupervisor {
  GitForegroundProcessSupervisor({
    this.maximumPendingOutputCharacters = _maximumPendingOutputCharacters,
    this.maximumEventCharacters = environmentProcessTextLimit,
    this.drainClock,
  }) {
    if (maximumPendingOutputCharacters < 1 ||
        maximumPendingOutputCharacters > _maximumPendingOutputCharacters) {
      throw ArgumentError.value(maximumPendingOutputCharacters);
    }
    if (maximumEventCharacters < 2 ||
        maximumEventCharacters > environmentProcessTextLimit) {
      throw ArgumentError.value(maximumEventCharacters);
    }
  }

  final int maximumPendingOutputCharacters;
  final int maximumEventCharacters;
  final GitForegroundProcessDrainClock? drainClock;
  final Set<_ForegroundProcessExecution> _active =
      <_ForegroundProcessExecution>{};
  bool _closing = false;
  Future<void>? _closeFuture;

  /// Full decoded Strings retained across active executions, including prefixes.
  int get pendingOutputCharacters => _active.fold(
    0,
    (total, execution) => total + execution._pendingCharacters,
  );

  Stream<EnvironmentProcessEvent> run({
    required EnvironmentId environmentId,
    required WorktreeEnvironment environment,
    required EnvironmentForegroundProcessRequest request,
  }) {
    late final _ForegroundProcessExecution execution;
    execution = _ForegroundProcessExecution(
      environmentId: environmentId,
      environment: environment,
      request: request,
      maximumPendingOutputCharacters: maximumPendingOutputCharacters,
      maximumEventCharacters: maximumEventCharacters,
      drainClock: drainClock ?? GitForegroundProcessDrainClock(),
      canStart: () => !_closing,
      onStarted: () => _active.add(execution),
      onFinished: () => _active.remove(execution),
    );
    return execution.stream;
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    await Future.wait<void>(
      _active
          .toList(growable: false)
          .map(
            (_ForegroundProcessExecution execution) =>
                execution.cancel(closeStream: true),
          ),
    );
  }
}

/// Supervisor-local monotonic clock seam; not an Environment request setting.
class GitForegroundProcessDrainClock {
  final Stopwatch _watch = Stopwatch()..start();

  Duration get elapsed => _watch.elapsed;

  Timer schedule(Duration delay, void Function() callback) =>
      Timer(delay, callback);
}

final class _LinuxEffectiveAccess {
  _LinuxEffectiveAccess() {
    final DynamicLibrary libc = DynamicLibrary.open('libc.so.6');
    _faccessat = libc.lookupFunction<_FaccessatNative, _FaccessatDart>(
      'faccessat',
    );
    _malloc = libc.lookupFunction<_MallocNative, _MallocDart>('malloc');
    _free = libc.lookupFunction<_FreeNative, _FreeDart>('free');
  }

  late final _FaccessatDart _faccessat;
  late final _MallocDart _malloc;
  late final _FreeDart _free;

  bool canExecute(String path) {
    final List<int> encoded = utf8.encode(path);
    final Pointer<Uint8> nativePath = _malloc(encoded.length + 1).cast();
    if (nativePath.address == 0) {
      throw StateError('Could not allocate executable access path.');
    }
    try {
      nativePath.asTypedList(encoded.length + 1)
        ..setAll(0, encoded)
        ..[encoded.length] = 0;
      return _faccessat(
            _atCurrentWorkingDirectory,
            nativePath,
            _executeAccess,
            _atEffectiveAccess,
          ) ==
          0;
    } finally {
      _free(nativePath.cast());
    }
  }
}

final _LinuxEffectiveAccess _linuxEffectiveAccess = _LinuxEffectiveAccess();

final class _ForegroundProcessExecution {
  _ForegroundProcessExecution({
    required this.environmentId,
    required this.environment,
    required this.request,
    required this.maximumPendingOutputCharacters,
    required this.maximumEventCharacters,
    required this.drainClock,
    required bool Function() canStart,
    required void Function() onStarted,
    required void Function() onFinished,
  }) : _canStart = canStart,
       _onStarted = onStarted,
       _onFinished = onFinished {
    _controller = StreamController<EnvironmentProcessEvent>(
      sync: true,
      onListen: () {
        if (_canStart()) _onStarted();
        unawaited(_run());
      },
      onPause: _pauseOutputSubscriptions,
      onResume: _scheduleOutput,
      onCancel: () => _producerClosing ? null : cancel(),
    );
  }

  final EnvironmentId environmentId;
  final WorktreeEnvironment environment;
  final EnvironmentForegroundProcessRequest request;
  final int maximumPendingOutputCharacters;
  final int maximumEventCharacters;
  final GitForegroundProcessDrainClock drainClock;
  final bool Function() _canStart;
  final void Function() _onStarted;
  final void Function() _onFinished;
  final Completer<void> _finished = Completer<void>();
  final Completer<void> _stdoutDone = Completer<void>();
  final Completer<void> _stderrDone = Completer<void>();
  final Completer<void> _outputDelivered = Completer<void>();
  late final StreamController<EnvironmentProcessEvent> _controller;
  final Queue<_PendingOutput> _pendingOutput = Queue<_PendingOutput>();
  // Emitted prefixes remain charged until their entire String leaves the queue.
  int _pendingCharacters = 0;
  EnvironmentProcessOutputStream? _lastReadStream;
  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  Future<int>? _exitCode;
  Timer? _timeout;
  Timer? _outputPump;
  Timer? _drainTimer;
  Duration? _drainActiveSince;
  Duration _drainIdleRemaining = _processPipeCloseGrace;
  Duration _drainHardRemaining = _processMaximumDrain;
  bool _draining = false;
  Future<void>? _outputCancellation;
  Future<void>? _terminationFuture;
  bool _cancelled = false;
  bool _timedOut = false;
  bool _leaderExited = false;
  bool _producerClosing = false;
  String? _outputFailure;
  bool _stdoutTruncated = false;
  bool _stderrTruncated = false;

  Stream<EnvironmentProcessEvent> get stream => _controller.stream;

  Future<void> cancel({bool closeStream = false}) async {
    if (!_cancelled) {
      _cancelled = true;
      _timeout?.cancel();
      await _terminateProcessGroup();
      await _cancelOutputSubscriptions();
    }
    await _finished.future;
    if (closeStream && !_producerClosing) _closeController();
  }

  Future<void> _run() async {
    try {
      _requireSupportedPlatform();
      if (!_canStart()) {
        throw _failure(
          'process_provider_closed',
          'The Environment provider is shutting down.',
        );
      }
      Directory workingDirectory = await environment
          .resolveProcessWorkingDirectory(request.relativeWorkingDirectory);
      if (_cancelled) return;
      final Map<String, String> childEnvironment = _childEnvironment(
        workingDirectory,
      );
      final String executable = await _resolveExecutable(
        request.program,
        workingDirectory,
        childEnvironment['PATH']!,
      );
      final String launcher = await _resolveSetSid();

      // Resolve again immediately before spawn so aliases cannot silently move
      // this invocation to a different directory during setup.
      final Directory revalidated = await environment
          .resolveProcessWorkingDirectory(request.relativeWorkingDirectory);
      if (revalidated.path != workingDirectory.path) {
        throw _failure(
          'process_working_directory_changed',
          'The process working directory changed while it was being resolved.',
          details: <String, Object?>{
            'relativeWorkingDirectory': request.relativeWorkingDirectory,
          },
        );
      }
      workingDirectory = revalidated;
      if (_cancelled || !_canStart()) return;

      final Process process;
      try {
        process = await Process.start(
          launcher,
          <String>['--', executable, ...request.arguments],
          workingDirectory: workingDirectory.path,
          environment: childEnvironment,
          includeParentEnvironment: false,
          runInShell: false,
          mode: ProcessStartMode.normal,
        );
      } on ProcessException catch (error) {
        throw _failure(
          'process_start_failed',
          'The foreground process could not be started.',
          details: <String, Object?>{'reason': error.message},
        );
      }
      _process = process;
      final Future<int> exitCodeFuture = process.exitCode.then((int value) {
        _leaderExited = true;
        return value;
      });
      _exitCode = exitCodeFuture;
      unawaited(process.stdin.close().catchError((Object _) {}));
      _listenToOutput(process);
      _timeout = Timer(Duration(seconds: request.timeoutSeconds), () {
        if (_cancelled || _producerClosing) return;
        _timedOut = true;
        if (_controller.isPaused && !_outputDelivered.isCompleted) {
          _failOutput('process_output_incomplete');
        }
        unawaited(_terminateProcessGroup());
      });
      if (_cancelled || !_canStart()) {
        await _terminateProcessGroup();
        await _cancelOutputSubscriptions();
        return;
      }

      final int exitCode = await exitCodeFuture;
      _timeout?.cancel();
      await _terminateProcessGroup();
      if (_cancelled) {
        await _cancelOutputSubscriptions();
        return;
      }
      await _settleOutputSubscriptions();
      if (_cancelled) return;
      if (_outputFailure case final String code) {
        throw _failure(
          code,
          'The foreground process output is incomplete.',
          details: <String, Object?>{
            'outputIncomplete': true,
            'termination': _timedOut ? 'timedOut' : 'exited',
            'exitCode': _timedOut ? null : exitCode,
            'stdoutTruncated': _stdoutTruncated,
            'stderrTruncated': _stderrTruncated,
          },
        );
      }

      _controller.add(
        EnvironmentProcessEvent(
          kind: EnvironmentProcessEventKind.completed,
          output: null,
          completed: EnvironmentProcessCompleted(
            termination: _timedOut
                ? EnvironmentProcessTermination.timedOut
                : EnvironmentProcessTermination.exited,
            exitCode: _timedOut ? null : exitCode,
            stdoutTruncated: _stdoutTruncated,
            stderrTruncated: _stderrTruncated,
          ),
        ),
      );
      _closeController();
    } on Object catch (error, stackTrace) {
      _timeout?.cancel();
      await _terminateProcessGroup();
      await _cancelOutputSubscriptions();
      if (!_cancelled) {
        _controller.addError(
          error is EnvironmentFailure
              ? error
              : _failure(
                  'process_execution_failed',
                  'The foreground process execution failed.',
                  details: <String, Object?>{'reason': error.toString()},
                ),
          stackTrace,
        );
        _closeController();
      }
    } finally {
      _timeout?.cancel();
      _onFinished();
      if (!_finished.isCompleted) _finished.complete();
    }
  }

  void _listenToOutput(Process process) {
    _stdoutSubscription = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (String text) =>
              _enqueueOutput(EnvironmentProcessOutputStream.stdout, text),
          onError: (Object error, StackTrace _) {
            _failOutput('process_output_failed');
          },
          onDone: () {
            if (!_stdoutDone.isCompleted) _stdoutDone.complete();
            _noteOutputProgress();
            _scheduleOutput();
          },
          cancelOnError: true,
        );
    _stderrSubscription = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (String text) =>
              _enqueueOutput(EnvironmentProcessOutputStream.stderr, text),
          onError: (Object error, StackTrace _) {
            _failOutput('process_output_failed');
          },
          onDone: () {
            if (!_stderrDone.isCompleted) _stderrDone.complete();
            _noteOutputProgress();
            _scheduleOutput();
          },
          cancelOnError: true,
        );
    if (_controller.isPaused) _pauseOutputSubscriptions();
  }

  void _enqueueOutput(EnvironmentProcessOutputStream stream, String text) {
    if (_cancelled ||
        _producerClosing ||
        _outputFailure != null ||
        text.isEmpty) {
      return;
    }
    // One admitted OS read can span several transport messages. Hold its
    // remainder here, not in the controller's otherwise unbounded paused queue.
    _pauseOutputSubscriptions();
    if (_cancelled || _outputFailure != null) return;
    if (text.length > maximumPendingOutputCharacters - _pendingCharacters) {
      _failOutput('process_output_overflow');
      return;
    }
    _pendingOutput.add(_PendingOutput(stream, text));
    _pendingCharacters += text.length;
    _lastReadStream = stream;
    _noteOutputProgress();
    _scheduleOutput();
  }

  void _pauseOutputSubscriptions() {
    for (final subscription in [_stdoutSubscription, _stderrSubscription]) {
      if (subscription != null && !subscription.isPaused) subscription.pause();
    }
    if (_timedOut && _controller.isPaused && !_outputDelivered.isCompleted) {
      _failOutput('process_output_incomplete');
    }
    _updateDrainDeadline();
  }

  void _scheduleOutput() {
    if (_cancelled || _producerClosing || _outputFailure != null) return;
    if (_pendingOutput.isEmpty &&
        _stdoutDone.isCompleted &&
        _stderrDone.isCompleted) {
      if (!_outputDelivered.isCompleted) _outputDelivered.complete();
      return;
    }
    if (_controller.isPaused || _outputPump != null) return;
    // Yield to the event queue between messages: both pipes and termination
    // timers must progress even when one pipe is continuously readable.
    _outputPump = Timer(Duration.zero, _pumpOutput);
  }

  void _pumpOutput() {
    _outputPump = null;
    if (_cancelled ||
        _producerClosing ||
        _outputFailure != null ||
        _controller.isPaused) {
      return;
    }
    if (_pendingOutput.isNotEmpty) {
      final _PendingOutput pending = _pendingOutput.first;
      final int end = _safeBoundary(
        pending.text,
        pending.offset,
        maximumEventCharacters,
      );
      final String text = pending.text.substring(pending.offset, end);
      pending.offset = end;
      if (end == pending.text.length) {
        _pendingOutput.removeFirst();
        _pendingCharacters -= pending.text.length;
      }
      _controller.add(
        EnvironmentProcessEvent(
          kind: EnvironmentProcessEventKind.output,
          output: EnvironmentProcessOutput(stream: pending.stream, text: text),
          completed: null,
        ),
      );
      if (_cancelled || _producerClosing || _outputFailure != null) return;
    }
    if (_pendingOutput.isEmpty && !_controller.isPaused) {
      // Give the other pipe first opportunity after an admitted read. A busy
      // stdout must not repeatedly pause stderr before it can be observed.
      final subscriptions =
          _lastReadStream == EnvironmentProcessOutputStream.stdout
          ? [_stderrSubscription, _stdoutSubscription]
          : [_stdoutSubscription, _stderrSubscription];
      for (final subscription in subscriptions) {
        if (subscription != null && subscription.isPaused) {
          subscription.resume();
        }
      }
      _updateDrainDeadline();
    }
    if (_pendingOutput.isNotEmpty ||
        (_stdoutDone.isCompleted && _stderrDone.isCompleted)) {
      _scheduleOutput();
    }
  }

  void _failOutput(String code) {
    if (_outputFailure != null || _cancelled) return;
    _outputFailure = code;
    _stdoutTruncated =
        !_stdoutDone.isCompleted ||
        _pendingOutput.any(
          (pending) => pending.stream == EnvironmentProcessOutputStream.stdout,
        );
    _stderrTruncated =
        !_stderrDone.isCompleted ||
        _pendingOutput.any(
          (pending) => pending.stream == EnvironmentProcessOutputStream.stderr,
        );
    unawaited(_cancelOutputSubscriptions());
    unawaited(_terminateProcessGroup());
  }

  Future<void> _terminateProcessGroup() {
    final Process? process = _process;
    if (process == null) return Future<void>.value();
    return _terminationFuture ??= () async {
      final bool leaderWasRunning = !_leaderExited;
      final bool groupFound = _killProcessGroup(
        process.pid,
        ProcessSignal.sigterm,
      );
      final bool leaderFound = groupFound || _leaderExited
          ? groupFound
          : _killProcess(process.pid, ProcessSignal.sigterm);
      if (leaderWasRunning || groupFound || leaderFound) {
        await Future<void>.delayed(_processTerminationGrace);
        // Re-probe the group after the grace period in case setsid won the
        // creation race after the initial TERM attempt.
        _killProcessGroup(process.pid, ProcessSignal.sigkill);
        if (!_leaderExited) {
          _killProcess(process.pid, ProcessSignal.sigkill);
        }
      }
      try {
        await (_exitCode ?? process.exitCode);
      } on Object {
        // Process termination remains best effort after a successful spawn.
      }
    }();
  }

  Future<void> _settleOutputSubscriptions() async {
    if (_outputDelivered.isCompleted) return;
    _draining = true;
    _updateDrainDeadline();
    try {
      await _outputDelivered.future;
    } finally {
      _draining = false;
      _drainTimer?.cancel();
      _drainTimer = null;
    }
  }

  void _noteOutputProgress() => _updateDrainDeadline(pipeProgress: true);

  void _updateDrainDeadline({bool pipeProgress = false}) {
    if (!_draining) return;
    final Duration now = drainClock.elapsed;
    if (_drainActiveSince case final Duration since) {
      final Duration elapsed = now - since;
      _drainIdleRemaining -= elapsed;
      _drainHardRemaining -= elapsed;
      _drainActiveSince = null;
    }
    _drainTimer?.cancel();
    _drainTimer = null;
    if (pipeProgress) _drainIdleRemaining = _processPipeCloseGrace;
    if (_cancelled ||
        _outputFailure != null ||
        (_stdoutDone.isCompleted && _stderrDone.isCompleted)) {
      return;
    }
    if (_drainIdleRemaining <= Duration.zero ||
        _drainHardRemaining <= Duration.zero) {
      _failOutput('process_output_incomplete');
      return;
    }
    // These budgets measure upstream liveness, not downstream delivery. Actual
    // reads are paused while credit or an admitted String's remainder is pending.
    // Keep the remaining hard budget across pauses so an escaped writer cannot
    // reset it with each read. EOF ends both clocks, but not queued delivery.
    final bool reading =
        (!_stdoutDone.isCompleted && _stdoutSubscription?.isPaused == false) ||
        (!_stderrDone.isCompleted && _stderrSubscription?.isPaused == false);
    if (!reading) return;
    _drainActiveSince = now;
    _drainTimer = drainClock.schedule(
      _drainIdleRemaining < _drainHardRemaining
          ? _drainIdleRemaining
          : _drainHardRemaining,
      _updateDrainDeadline,
    );
  }

  Future<void> _cancelOutputSubscriptions() {
    // Cancellation can race Process.start; do not memoize before pipes exist.
    if (_stdoutSubscription == null && _stderrSubscription == null) {
      return Future<void>.value();
    }
    return _outputCancellation ??= () async {
      _drainTimer?.cancel();
      _drainTimer = null;
      _outputPump?.cancel();
      _outputPump = null;
      _pendingOutput.clear();
      _pendingCharacters = 0;
      final List<Future<void>> cancellations = <Future<void>>[];
      for (final StreamSubscription<String>? subscription
          in <StreamSubscription<String>?>[
            _stdoutSubscription,
            _stderrSubscription,
          ]) {
        if (subscription != null) {
          cancellations.add(subscription.cancel().catchError((Object _) {}));
        }
      }
      await Future.wait<void>(cancellations);
      if (!_outputDelivered.isCompleted) _outputDelivered.complete();
    }();
  }

  void _closeController() {
    if (_producerClosing) return;
    _producerClosing = true;
    unawaited(_controller.close());
  }

  EnvironmentFailure _failure(
    String code,
    String message, {
    Map<String, Object?> details = const <String, Object?>{},
  }) => EnvironmentFailure(
    code: code,
    message: message,
    details: <String, Object?>{
      'environmentId': environmentId.value,
      ...details,
    },
  );
}

final class _PendingOutput {
  _PendingOutput(this.stream, this.text);

  final EnvironmentProcessOutputStream stream;
  final String text;
  int offset = 0;
}

int _safeBoundary(String text, int start, int maximumLength) {
  int end = start + maximumLength;
  if (end >= text.length) return text.length;
  if (_isHighSurrogate(text.codeUnitAt(end - 1))) end--;
  return end;
}

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xd800 && codeUnit <= 0xdbff;

void _requireSupportedPlatform() {
  if (!Platform.isLinux || Abi.current() != Abi.linuxX64) {
    throw const EnvironmentFailure(
      code: 'process_execution_unsupported',
      message:
          'Foreground process execution is currently supported on Linux x64.',
      details: <String, Object?>{},
    );
  }
}

Future<String> _resolveSetSid() async {
  for (final String candidate in const <String>[
    '/usr/bin/setsid',
    '/bin/setsid',
  ]) {
    if (await _isExecutableFile(candidate)) return candidate;
  }
  throw const EnvironmentFailure(
    code: 'process_launcher_unavailable',
    message:
        'Foreground process execution requires the util-linux setsid tool.',
    details: <String, Object?>{},
  );
}

Map<String, String> _childEnvironment(Directory workingDirectory) {
  final Map<String, String> environment = <String, String>{};
  for (final MapEntry<String, String> entry in Platform.environment.entries) {
    if (_retainedEnvironmentVariables.contains(entry.key) ||
        entry.key.startsWith('LC_')) {
      environment[entry.key] = entry.value;
    }
  }
  environment['PATH'] = environment['PATH']?.isNotEmpty == true
      ? environment['PATH']!
      : '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';
  environment['PWD'] = workingDirectory.path;
  environment['TERM'] = 'dumb';
  return environment;
}

Future<String> _resolveExecutable(
  String program,
  Directory workingDirectory,
  String path,
) async {
  if (program.contains('/')) {
    final String candidate = program.startsWith('/')
        ? program
        : '${workingDirectory.path}/$program';
    return _requireExecutable(candidate, program);
  }
  bool foundNonExecutable = false;
  for (final String entry in path.split(':')) {
    final String directory = entry.isEmpty
        ? workingDirectory.path
        : entry.startsWith('/')
        ? entry
        : '${workingDirectory.path}/$entry';
    final String candidate = '$directory/$program';
    final FileStat stat = await FileStat.stat(candidate);
    if (stat.type != FileSystemEntityType.file) continue;
    if (_linuxEffectiveAccess.canExecute(candidate)) {
      return _requireExecutable(candidate, program);
    }
    foundNonExecutable = true;
  }
  throw EnvironmentFailure(
    code: foundNonExecutable
        ? 'process_start_failed'
        : 'process_executable_not_found',
    message: foundNonExecutable
        ? 'The foreground process executable is not executable.'
        : 'The foreground process executable was not found.',
    details: <String, Object?>{'program': program},
  );
}

Future<String> _requireExecutable(String candidate, String program) async {
  final FileStat stat = await FileStat.stat(candidate);
  if (stat.type != FileSystemEntityType.file) {
    throw EnvironmentFailure(
      code: 'process_executable_not_found',
      message: 'The foreground process executable was not found.',
      details: <String, Object?>{'program': program},
    );
  }
  if (!_linuxEffectiveAccess.canExecute(candidate)) {
    throw EnvironmentFailure(
      code: 'process_start_failed',
      message: 'The foreground process executable is not executable.',
      details: <String, Object?>{'program': program},
    );
  }
  return File(candidate).resolveSymbolicLinks();
}

Future<bool> _isExecutableFile(String path) async {
  final FileStat stat = await FileStat.stat(path);
  return stat.type == FileSystemEntityType.file &&
      _linuxEffectiveAccess.canExecute(path);
}

bool _killProcessGroup(int processId, ProcessSignal signal) {
  try {
    return Process.killPid(-processId, signal);
  } on Object {
    return false;
  }
}

bool _killProcess(int processId, ProcessSignal signal) {
  try {
    return Process.killPid(processId, signal);
  } on Object {
    return false;
  }
}
