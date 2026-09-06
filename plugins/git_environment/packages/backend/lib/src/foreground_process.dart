import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';

import 'worktree_environment.dart';

const int maximumEnvironmentProcessOutputCharacters = 1024 * 1024;
const int _processOutputHeadCharacters =
    maximumEnvironmentProcessOutputCharacters ~/ 2;
const int _processOutputTailCharacters =
    maximumEnvironmentProcessOutputCharacters - _processOutputHeadCharacters;
const int _maximumProcessEventCharacters = 16 * 1024;
const Duration _processTerminationGrace = Duration(milliseconds: 250);
const Duration _processPipeCloseGrace = Duration(seconds: 1);

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
  final Set<_ForegroundProcessExecution> _active =
      <_ForegroundProcessExecution>{};
  bool _closing = false;
  Future<void>? _closeFuture;

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

final class _ForegroundProcessExecution {
  _ForegroundProcessExecution({
    required this.environmentId,
    required this.environment,
    required this.request,
    required bool Function() canStart,
    required void Function() onStarted,
    required void Function() onFinished,
  }) : _canStart = canStart,
       _onStarted = onStarted,
       _onFinished = onFinished {
    _stdoutOutput = _BoundedTextOutput(
      stream: EnvironmentProcessOutputStream.stdout,
      emit: _emitOutput,
    );
    _stderrOutput = _BoundedTextOutput(
      stream: EnvironmentProcessOutputStream.stderr,
      emit: _emitOutput,
    );
    _controller = StreamController<EnvironmentProcessEvent>(
      sync: true,
      onListen: () {
        if (_canStart()) _onStarted();
        unawaited(_run());
      },
      onCancel: () => _producerClosing ? null : cancel(),
    );
  }

  final EnvironmentId environmentId;
  final WorktreeEnvironment environment;
  final EnvironmentForegroundProcessRequest request;
  final bool Function() _canStart;
  final void Function() _onStarted;
  final void Function() _onFinished;
  final Completer<void> _finished = Completer<void>();
  final Completer<void> _stdoutDone = Completer<void>();
  final Completer<void> _stderrDone = Completer<void>();
  late final StreamController<EnvironmentProcessEvent> _controller;
  late final _BoundedTextOutput _stdoutOutput;
  late final _BoundedTextOutput _stderrOutput;
  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  Future<int>? _exitCode;
  Timer? _timeout;
  Future<void>? _terminationFuture;
  bool _cancelled = false;
  bool _timedOut = false;
  bool _leaderExited = false;
  bool _producerClosing = false;
  Object? _outputError;

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
      if (_outputError case final Object error) {
        throw _failure(
          'process_output_failed',
          'The foreground process output could not be read.',
          details: <String, Object?>{'reason': error.toString()},
        );
      }
      if (_cancelled) return;

      _stdoutOutput.flushTail();
      _stderrOutput.flushTail();
      _controller.add(
        EnvironmentProcessEvent(
          kind: EnvironmentProcessEventKind.completed,
          output: null,
          completed: EnvironmentProcessCompleted(
            termination: _timedOut
                ? EnvironmentProcessTermination.timedOut
                : EnvironmentProcessTermination.exited,
            exitCode: _timedOut ? null : exitCode,
            stdoutTruncated: _stdoutOutput.truncated,
            stderrTruncated: _stderrOutput.truncated,
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
          _stdoutOutput.add,
          onError: (Object error, StackTrace _) {
            _outputError ??= error;
            if (!_stdoutDone.isCompleted) _stdoutDone.complete();
            unawaited(_terminateProcessGroup());
          },
          onDone: () {
            if (!_stdoutDone.isCompleted) _stdoutDone.complete();
          },
          cancelOnError: true,
        );
    _stderrSubscription = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          _stderrOutput.add,
          onError: (Object error, StackTrace _) {
            _outputError ??= error;
            if (!_stderrDone.isCompleted) _stderrDone.complete();
            unawaited(_terminateProcessGroup());
          },
          onDone: () {
            if (!_stderrDone.isCompleted) _stderrDone.complete();
          },
          cancelOnError: true,
        );
  }

  void _emitOutput(EnvironmentProcessOutputStream stream, String text) {
    if (_cancelled || _producerClosing || text.isEmpty) return;
    _controller.add(
      EnvironmentProcessEvent(
        kind: EnvironmentProcessEventKind.output,
        output: EnvironmentProcessOutput(stream: stream, text: text),
        completed: null,
      ),
    );
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
    try {
      await Future.wait<void>(<Future<void>>[
        _stdoutDone.future,
        _stderrDone.future,
      ]).timeout(_processPipeCloseGrace);
    } on TimeoutException {
      await _cancelOutputSubscriptions();
    }
  }

  Future<void> _cancelOutputSubscriptions() async {
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

final class _BoundedTextOutput {
  _BoundedTextOutput({required this.stream, required this.emit});

  final EnvironmentProcessOutputStream stream;
  final void Function(EnvironmentProcessOutputStream stream, String text) emit;
  int _headRemaining = _processOutputHeadCharacters;
  int _observed = 0;
  String _tail = '';

  bool get truncated => _observed > maximumEnvironmentProcessOutputCharacters;

  void add(String text) {
    if (text.isEmpty) return;
    _observed =
        _observed > maximumEnvironmentProcessOutputCharacters - text.length
        ? maximumEnvironmentProcessOutputCharacters + 1
        : _observed + text.length;
    int offset = 0;
    if (_headRemaining > 0) {
      final int requestedEnd = text.length < _headRemaining
          ? text.length
          : _headRemaining;
      final int end = _safeBoundary(text, 0, _headRemaining);
      _emitChunks(text.substring(0, end));
      offset = end;
      _headRemaining = end < requestedEnd ? 0 : _headRemaining - end;
    }
    if (offset < text.length) _retainTail(text.substring(offset));
  }

  void flushTail() {
    _emitChunks(_tail);
    _tail = '';
  }

  void _retainTail(String text) {
    if (text.length >= _processOutputTailCharacters) {
      int start = text.length - _processOutputTailCharacters;
      if (_isLowSurrogate(text.codeUnitAt(start))) start++;
      _tail = text.substring(start);
      return;
    }
    final String combined = '$_tail$text';
    if (combined.length <= _processOutputTailCharacters) {
      _tail = combined;
      return;
    }
    int start = combined.length - _processOutputTailCharacters;
    if (_isLowSurrogate(combined.codeUnitAt(start))) start++;
    _tail = combined.substring(start);
  }

  void _emitChunks(String text) {
    for (int offset = 0; offset < text.length;) {
      final int end = _safeBoundary(
        text,
        offset,
        _maximumProcessEventCharacters,
      );
      emit(stream, text.substring(offset, end));
      offset = end;
    }
  }
}

int _safeBoundary(String text, int start, int maximumLength) {
  int end = start + maximumLength;
  if (end >= text.length) return text.length;
  if (_isHighSurrogate(text.codeUnitAt(end - 1))) end--;
  return end;
}

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xd800 && codeUnit <= 0xdbff;

bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xdc00 && codeUnit <= 0xdfff;

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
    final String directory = entry.isEmpty ? workingDirectory.path : entry;
    final String candidate = '$directory/$program';
    final FileStat stat = await FileStat.stat(candidate);
    if (stat.type != FileSystemEntityType.file) continue;
    if (_hasExecuteBit(stat.mode)) {
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
  if (!_hasExecuteBit(stat.mode)) {
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
  return stat.type == FileSystemEntityType.file && _hasExecuteBit(stat.mode);
}

bool _hasExecuteBit(int mode) => mode & 0x49 != 0;

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
