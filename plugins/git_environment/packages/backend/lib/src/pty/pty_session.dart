import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// Provider-private Linux PTY, backed by an independently prepared executable.
///
/// The provider owns authorization, cwd confinement, executable resolution,
/// environment allowlisting, session count/lifetime and calling [close]. This
/// class owns one helper/PTY and bounded byte transport, not product semantics.
/// No native library, signal handler, cwd or environment mutation in the host.
/// The helper requires Linux 5.3+ pidfds and a mounted, accessible `/proc`.
final class GitPtySession {
  GitPtySession._(this._process) {
    _stdout = _process.stdout.listen(
      _receive,
      onError: (Object error) => _fail('PTY output failed: $error'),
      onDone: _outputDone.complete,
    );
    _stderr = _process.stderr.listen((bytes) {
      final remaining = 4096 - _diagnostics.length;
      if (remaining > 0) _diagnostics.addAll(bytes.take(remaining));
    }, onError: (Object error) => _fail('PTY diagnostics failed: $error'));
    unawaited(
      _process.stdin.done.then<void>(
        (_) {},
        onError: (Object error) {
          if (!_closing) _fail('PTY input failed: $error');
        },
      ),
    );
    unawaited(_finish());
  }

  static const maximumChunkBytes = 16 * 1024;
  static const maximumBufferedOutputBytes = 256 * 1024;

  /// Only absolute, caller-resolved paths; no PATH search or shell substitution.
  /// [environment] replaces (never merges with) the shared host environment.
  static Future<GitPtySession> start({
    required String helperPath,
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    required Map<String, String> environment,
    required int rows,
    required int columns,
  }) async {
    if (!Platform.isLinux || Abi.current() != Abi.linuxX64) {
      throw UnsupportedError('Git PTY currently supports Linux x64 only.');
    }
    for (final path in [helperPath, executable, workingDirectory]) {
      if (!path.startsWith('/') || path.contains('\u0000')) {
        throw ArgumentError('PTY paths must be absolute and contain no NUL.');
      }
    }
    _geometry(rows, columns);
    if (arguments.length > 256 ||
        environment.length > 256 ||
        arguments.any((s) => s.contains('\u0000')) ||
        environment.entries.any(
          (e) =>
              e.key.isEmpty ||
              e.key.contains('=') ||
              e.key.contains('\u0000') ||
              e.value.contains('\u0000'),
        ) ||
        [
              helperPath,
              executable,
              workingDirectory,
              ...arguments,
              ...environment.keys,
              ...environment.values,
            ].fold<int>(0, (n, s) => n + utf8.encode(s).length + 1) >
            64 * 1024) {
      throw ArgumentError('PTY argv/environment exceeds bounds or is invalid.');
    }
    final process = await Process.start(
      helperPath,
      ['--protocol=1', '$rows', '$columns', executable, ...arguments],
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
    );
    final session = GitPtySession._(process);
    try {
      await session._ready.future.timeout(const Duration(seconds: 6));
      session._checkFailure();
      if (session._pid == null) throw StateError('PTY exited before ready.');
      return session;
    } on Object {
      await session.close();
      rethrow;
    }
  }

  final Process _process;
  final _ready = Completer<void>();
  final _finished = Completer<void>();
  final _outputDone = Completer<void>();
  final _output = Queue<Uint8List>();
  final _diagnostics = <int>[];
  final _frame = Uint8List(maximumChunkBytes + 5);
  late final StreamSubscription<List<int>> _stdout;
  late final StreamSubscription<List<int>> _stderr;
  Completer<void>? _reader;
  Completer<void>? _ack;
  Future<void>? _closeFuture;
  Object? _failure;
  int? _pid;
  int? _status;
  int? _helperExitCode;
  int _used = 0;
  int _needed = 5;
  int _buffered = 0;
  bool _reading = false;
  bool _closing = false;

  int get pid => _pid!;

  /// Completes after the terminal's final output and helper cleanup. A lost
  /// helper/transport is an error, never a fabricated successful child exit.
  Future<int> get exitCode async {
    await _finished.future;
    _checkFailure();
    return _status!;
  }

  /// One reader at a time; returns <=16 KiB or null after EOF. Output is raw
  /// terminal bytes (stdout/stderr merged). Overflow fails the session explicitly
  /// and initiates cleanup instead of growing an unbounded stream queue.
  Future<Uint8List?> read() async {
    if (_reading) throw StateError('A PTY read is already pending.');
    _reading = true;
    try {
      while (true) {
        _checkFailure();
        if (_output.isNotEmpty) {
          final bytes = _output.removeFirst();
          _buffered -= bytes.length;
          return bytes;
        }
        if (_finished.isCompleted) return null;
        final reader = _reader = Completer<void>();
        await reader.future;
      }
    } finally {
      _reader = null;
      _reading = false;
    }
  }

  /// Acknowledged only after all bytes reach the PTY master. No command queue:
  /// callers must await each write/resize. A blocked write fails within 6 s.
  Future<void> write(Uint8List bytes) => _command(87, bytes);

  Future<void> resize({required int rows, required int columns}) {
    _geometry(rows, columns);
    final bytes = ByteData(4)
      ..setUint16(0, rows)
      ..setUint16(2, columns);
    return _command(83, bytes.buffer.asUint8List());
  }

  Future<void> _command(int type, Uint8List bytes) async {
    _checkFailure();
    if (_closing || _finished.isCompleted || _status != null) {
      throw StateError('PTY is closed.');
    }
    if (_ack != null) throw StateError('A PTY command is already pending.');
    if (bytes.length > maximumChunkBytes) {
      throw ArgumentError('PTY command exceeds $maximumChunkBytes bytes.');
    }
    final ack = _ack = Completer<void>();
    final data = Uint8List(5 + bytes.length);
    data[0] = type;
    ByteData.sublistView(data).setUint32(1, bytes.length);
    data.setRange(5, data.length, bytes);
    try {
      _process.stdin.add(data);
      await ack.future.timeout(const Duration(seconds: 6));
      _checkFailure();
      if (_closing || _finished.isCompleted) {
        throw StateError('PTY closed before command acknowledgement.');
      }
    } on Object catch (error) {
      // Cancelling an outstanding command must not erase a reaped child's exit
      // evidence or fail an independent reader during an intentional close.
      if (!_closing) _fail('PTY command failed: $error');
      rethrow;
    } finally {
      _ack = null;
    }
  }

  /// Idempotent, bounded TERM/KILL cleanup in the helper, including the shell's
  /// current foreground job-control group. Deliberate daemonization is excluded.
  /// Throws if cleanup failed or cannot be confirmed, independently of a prior
  /// transport/output failure. Repeated calls retain the same cleanup result.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    try {
      if (!_finished.isCompleted) {
        _process.kill(ProcessSignal.sigterm);
        try {
          await _finished.future.timeout(const Duration(seconds: 3));
        } on TimeoutException {
          _process.kill(ProcessSignal.sigkill);
          await _finished.future.timeout(const Duration(seconds: 2));
        }
      }
    } finally {
      await _stdout.cancel();
      await _stderr.cancel();
      unawaited(_process.stdin.close().catchError((Object _) {}));
    }
    // Private helper protocol: 0 and 125 confirm cleanup, even when an earlier
    // overflow made us stop decoding frames; 64 guarantees no child was spawned.
    // Signals/unrecognized exits are not evidence that descendants were reaped.
    final code = _helperExitCode;
    if (code != 0 && code != 125 && !(code == 64 && _pid == null)) {
      throw StateError(
        code == 126
            ? 'PTY cleanup did not complete (helper exit $code).'
            : 'PTY cleanup could not be confirmed (helper exit $code).',
      );
    }
  }

  void _receive(List<int> bytes) {
    if (_failure != null) return;
    var offset = 0;
    while (offset < bytes.length && _failure == null) {
      final count = (bytes.length - offset).clamp(0, _needed - _used);
      _frame.setRange(_used, _used + count, bytes, offset);
      offset += count;
      _used += count;
      if (_used == 5 && _needed == 5) {
        final size = ByteData.sublistView(_frame).getUint32(1);
        if (size > maximumChunkBytes) {
          _fail('Oversized PTY frame.');
          return;
        }
        _needed += size;
      }
      if (_used != _needed) continue;
      final size = _needed - 5;
      final type = _frame[0];
      if (type == 69) {
        _fail(utf8.decode(_frame.sublist(5, _needed), allowMalformed: true));
      } else if (type == 82 && size == 4 && _pid == null) {
        _pid = ByteData.sublistView(_frame).getUint32(5);
        _ready.complete();
      } else if (_pid == null || _status != null) {
        _fail('PTY frame outside session lifetime.');
      } else if (type == 79 && size > 0) {
        if (_buffered + size > maximumBufferedOutputBytes) {
          _fail(
            'PTY output exceeded $maximumBufferedOutputBytes unread bytes.',
          );
        } else {
          _output.add(Uint8List.fromList(_frame.sublist(5, _needed)));
          _buffered += size;
          _wake(_reader);
        }
      } else if (type == 65 &&
          size == 0 &&
          _ack != null &&
          !_ack!.isCompleted) {
        _ack!.complete();
      } else if (type == 88 && size == 4) {
        _status = ByteData.sublistView(_frame).getUint32(5);
      } else {
        _fail('Invalid PTY frame.');
      }
      _used = 0;
      _needed = 5;
    }
  }

  Future<void> _finish() async {
    final code = await _process.exitCode;
    _helperExitCode = code;
    try {
      await _outputDone.future.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      _failure ??= StateError('PTY output did not close.');
    }
    if (code != 0 || _status == null || _used != 0) {
      _failure ??= StateError(
        'PTY helper exited without a complete result ($code): '
        '${utf8.decode(_diagnostics, allowMalformed: true)}',
      );
    }
    _finished.complete();
    unawaited(_process.stdin.close().catchError((Object _) {}));
    _wake(_ready);
    _wake(_reader);
    _wake(_ack);
  }

  void _fail(String message) {
    _failure ??= StateError(message);
    _output.clear();
    _buffered = 0;
    _wake(_ready);
    _wake(_reader);
    _wake(_ack);
    unawaited(close().catchError((Object _) {}));
  }

  void _checkFailure() {
    if (_failure case final Object error) throw error;
  }

  static void _wake(Completer<void>? signal) {
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  static void _geometry(int rows, int columns) {
    if (rows < 1 || rows > 2000 || columns < 1 || columns > 1000) {
      throw ArgumentError(
        'PTY dimensions require 1..2000 rows, 1..1000 columns.',
      );
    }
  }
}
