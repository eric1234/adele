import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:crypto/crypto.dart';

import 'pty/pty_session.dart';
import 'worktree_environment.dart';

const int maximumGitTerminals = 16;
const int maximumGitTerminalsPerEnvironment = 4;
const int maximumGitTerminalChunkBytes = GitPtySession.maximumChunkBytes;

/// Provider-local injection boundary; implementations must bound native buffers,
/// fail explicitly on overflow, and unblock reads on close. The supervisor pauses
/// reads, not the shared output/control transport or its acknowledgements.
/// Preparation must not spawn a terminal. Start owns cleanup on failed startup.
abstract interface class GitTerminalDriver {
  Future<void> prepare();

  Future<GitTerminalSession> start({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    required Map<String, String> environment,
    required EnvironmentTerminalDimensions dimensions,
  });
}

abstract interface class GitTerminalSession {
  /// One outstanding read, 1..[maximumGitTerminalChunkBytes] bytes, null at EOF.
  Future<Uint8List?> read();
  Future<int> get exitCode;
  Future<void> write(Uint8List bytes);
  Future<void> resize(EnvironmentTerminalDimensions dimensions);
  Future<void> close();
}

final class GitTerminalSupervisor {
  GitTerminalSupervisor({
    GitTerminalDriver? driver,
    String? helperPath,
    Map<String, String>? parentEnvironment,
    this.operationDeadline = const Duration(seconds: 8),
  }) : _driver = driver ?? _NativeTerminalDriver(helperPath),
       _parentEnvironment = Map<String, String>.unmodifiable(
         parentEnvironment ?? Platform.environment,
       );

  final GitTerminalDriver _driver;
  // Provider-local test seam, still allowlisted; never a terminal request override.
  final Map<String, String> _parentEnvironment;
  final Duration operationDeadline;
  final Set<_TerminalResource> _active = <_TerminalResource>{};
  final Map<String, _TerminalResource> _handles = <String, _TerminalResource>{};
  final Random _random = Random.secure();
  late final Hmac _signer = Hmac(sha256, _randomBytes());
  bool _closing = false;
  Future<void>? _closeFuture;

  Stream<EnvironmentTerminalEvent> open({
    required EnvironmentId environmentId,
    required WorktreeEnvironment Function() resolveEnvironment,
    required EnvironmentTerminalRequest request,
  }) => _TerminalResource(
    this,
    environmentId,
    resolveEnvironment,
    request,
  ).stream;

  void _admit(_TerminalResource resource) {
    if (_closing) {
      throw _failure(
        'terminal_provider_closed',
        'The provider is shutting down.',
      );
    }
    if (_active.length >= maximumGitTerminals ||
        _active
                .where((entry) => entry.environmentId == resource.environmentId)
                .length >=
            maximumGitTerminalsPerEnvironment) {
      throw _failure(
        'terminal_limit',
        'The terminal resource limit was reached.',
      );
    }
    // Includes starts before any filesystem/native await and pending cleanup.
    _active.add(resource);
  }

  Future<void> write(
    EnvironmentId environmentId,
    String handle,
    String text,
  ) async {
    final resource = _live(environmentId, handle);
    validateEnvironmentTerminalText(text);
    await resource.control(() async {
      final bytes = utf8.encode(text);
      for (
        var offset = 0;
        offset < bytes.length;
        offset += maximumGitTerminalChunkBytes
      ) {
        resource.requireLive();
        await resource.session!.write(
          Uint8List.sublistView(
            bytes,
            offset,
            min(offset + maximumGitTerminalChunkBytes, bytes.length),
          ),
        );
      }
    });
  }

  Future<void> resize(
    EnvironmentId environmentId,
    String handle,
    EnvironmentTerminalDimensions dimensions,
  ) async {
    final resource = _live(environmentId, handle);
    await resource.control(() => resource.session!.resize(dimensions));
  }

  Future<void> closeTerminal(EnvironmentId environmentId, String handle) async {
    _requireOwned(environmentId, handle);
    await _handles[handle]?.close();
  }

  _TerminalResource _live(EnvironmentId environmentId, String handle) {
    _requireOwned(environmentId, handle);
    final resource = _handles[handle];
    if (_closing || resource == null) {
      throw _failure('terminal_gone', 'The terminal is no longer live.');
    }
    resource.requireLive();
    return resource;
  }

  // Authenticated generation-local handles make retired close idempotent without
  // retaining an ever-growing tombstone table. Environment identity is signed,
  // not inferred from a caller-supplied pid or exposed in the handle.
  String _newHandle(EnvironmentId environmentId) {
    final nonce = base64Url.encode(_randomBytes()).replaceAll('=', '');
    return '$nonce.${_signature(environmentId, nonce)}';
  }

  List<int> _randomBytes() =>
      List<int>.generate(24, (_) => _random.nextInt(256));

  String _signature(EnvironmentId environmentId, String nonce) => base64Url
      .encode(
        _signer
            .convert(utf8.encode(jsonEncode([environmentId.value, nonce])))
            .bytes,
      )
      .replaceAll('=', '');

  void _requireOwned(EnvironmentId environmentId, String handle) {
    if (!RegExp(r'^[A-Za-z0-9_-]{32}\.[A-Za-z0-9_-]{43}$').hasMatch(handle)) {
      throw _failure(
        'invalid_terminal_handle',
        'The terminal handle is not owned by this Environment.',
      );
    }
    final expected = _signature(environmentId, handle.substring(0, 32));
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected.codeUnitAt(i) ^ handle.codeUnitAt(i + 33);
    }
    if (difference != 0) {
      throw _failure(
        'invalid_terminal_handle',
        'The terminal handle is not owned by this Environment.',
      );
    }
  }

  /// Fences admission synchronously, including streams created but not listened.
  Future<void> close() {
    _closing = true;
    return _closeFuture ??= Future.wait<void>(
      _active.toList(growable: false).map((resource) => resource.close()),
    );
  }
}

final class _TerminalResource {
  _TerminalResource(
    this.owner,
    this.environmentId,
    this.resolveEnvironment,
    this.request,
  ) {
    _controller = StreamController<EnvironmentTerminalEvent>(
      sync: true,
      onListen: () => unawaited(_run()),
      onPause: () {
        _paused = true;
      },
      onResume: () {
        _paused = false;
        _wake();
      },
      onCancel: () {
        if (_producerClosed) return null;
        _abandoned = true;
        return close();
      },
    );
  }

  final GitTerminalSupervisor owner;
  final EnvironmentId environmentId;
  final WorktreeEnvironment Function() resolveEnvironment;
  final EnvironmentTerminalRequest request;
  late final StreamController<EnvironmentTerminalEvent> _controller;
  final Completer<void> _finished = Completer<void>();
  Completer<void>? _credit;
  GitTerminalSession? session;
  String? _handle;
  bool _paused = false;
  bool _closing = false;
  bool _abandoned = false;
  bool _producerClosed = false;
  bool _exited = false;
  bool _controlPending = false;
  Future<void>? _nativeClose;
  Future<void>? _closeFuture;
  Object? _failureReason;
  Object? _cleanupFailure;

  Stream<EnvironmentTerminalEvent> get stream => _controller.stream;

  void requireLive() {
    if (_closing || _exited || _producerClosed || session == null) {
      throw _failure('terminal_gone', 'The terminal is no longer live.');
    }
  }

  Future<void> control(Future<void> Function() operation) async {
    requireLive();
    if (_controlPending) {
      throw _failure(
        'terminal_busy',
        'A terminal control operation is already pending.',
      );
    }
    _controlPending = true;
    try {
      // No unbounded serialized native-command queue in front of router shutdown.
      await operation().timeout(owner.operationDeadline);
      requireLive();
    } on Object catch (error) {
      if (_closing) {
        throw _failure('terminal_gone', 'The terminal is no longer live.');
      }
      _failureReason ??= _failure(
        'terminal_control_failed',
        'The terminal control operation failed.',
      );
      unawaited(close().catchError((Object _) {}));
      throw error is EnvironmentFailure ? error : _failureReason!;
    } finally {
      _controlPending = false;
    }
  }

  Future<void> close() {
    _closing = true;
    _wake();
    // Native close does not depend on output credit or a pending write/resize.
    unawaited(
      _closeNative().catchError((Object error) {
        _failureReason ??= error;
      }),
    );
    return _closeFuture ??= _finished.future
        .then<void>((_) {
          if (_cleanupFailure != null) {
            throw _failure(
              'terminal_cleanup_failed',
              'The terminal could not be closed.',
            );
          }
        })
        .timeout(owner.operationDeadline);
  }

  Future<void> _closeNative() {
    final native = session;
    if (native == null) return Future<void>.value();
    return _nativeClose ??= Future<void>.sync(
      native.close,
    ).timeout(owner.operationDeadline);
  }

  Future<void> _run() async {
    var reportedFailure = false;
    try {
      owner._admit(this);
      final environment = resolveEnvironment();
      final workingDirectory = await environment.resolveProcessWorkingDirectory(
        request.relativeWorkingDirectory,
      );
      if (_closing) return;
      final childEnvironment = _childEnvironment(
        workingDirectory,
        owner._parentEnvironment,
      );
      await owner._driver.prepare();
      if (_closing) return;
      final (program, arguments) = switch (request.launchKind) {
        EnvironmentTerminalLaunchKind.explicitProgram => (
          request.program!,
          request.arguments,
        ),
        EnvironmentTerminalLaunchKind.defaultShell => (
          childEnvironment['SHELL'] ?? '/bin/sh',
          const <String>['-i'],
        ),
      };
      final executable = await _resolveExecutable(
        program,
        workingDirectory,
        childEnvironment['PATH']!,
      );
      final revalidated = await environment.resolveProcessWorkingDirectory(
        request.relativeWorkingDirectory,
      );
      if (revalidated.path != workingDirectory.path) {
        throw _failure(
          'terminal_working_directory_changed',
          'The terminal working directory changed during setup.',
        );
      }
      if (_closing) return;
      session = await owner._driver.start(
        executable: executable,
        arguments: arguments,
        workingDirectory: revalidated.path,
        environment: childEnvironment,
        dimensions: request.dimensions,
      );
      // Cancellation/shutdown may win while the native start is awaiting ready.
      if (_closing) return;
      final handle = _handle = owner._newHandle(environmentId);
      owner._handles[handle] = this;
      _controller.add(
        EnvironmentTerminalEvent(
          kind: EnvironmentTerminalEventKind.opened,
          opened: EnvironmentTerminalOpened(
            handle: handle,
            dimensions: request.dimensions,
          ),
          output: null,
          completed: null,
        ),
      );

      int? exitStatus;
      final exit = session!.exitCode.then<void>(
        (code) {
          _exited = true;
          exitStatus = code;
        },
        onError: (Object error) {
          _failureReason ??= error;
          unawaited(close().catchError((Object _) {}));
        },
      );
      final decoded = _DecodedText();
      final decoder = const Utf8Decoder(
        allowMalformed: true,
      ).startChunkedConversion(StringConversionSink.from(decoded));
      while (!_closing) {
        await _waitForCredit();
        if (_closing) break;
        if (_paused) continue;
        final bytes = await session!.read();
        if (_closing) break;
        if (bytes == null) {
          decoder.close();
          await _emitText(decoded.take());
          await exit;
          break;
        }
        if (bytes.isEmpty || bytes.length > maximumGitTerminalChunkBytes) {
          throw _failure(
            'terminal_output_failed',
            'The native terminal exceeded its output chunk bound.',
          );
        }
        decoder.add(bytes);
        await _emitText(decoded.take());
      }
      await _closeNative();
      if (_failureReason case final error?) throw error;
      if (!_abandoned) {
        _controller.add(
          EnvironmentTerminalEvent(
            kind: EnvironmentTerminalEventKind.completed,
            opened: null,
            output: null,
            completed: EnvironmentTerminalCompleted(
              termination: _closing
                  ? EnvironmentTerminalTermination.closed
                  : EnvironmentTerminalTermination.exited,
              exitCode: _closing ? null : exitStatus,
            ),
          ),
        );
      }
    } on Object catch (error, stack) {
      _closing = true;
      reportedFailure = true;
      if (!_abandoned) {
        _controller.addError(
          error is EnvironmentFailure
              ? error
              : _failure(
                  'terminal_failed',
                  'The terminal could not complete its operation.',
                ),
          stack,
        );
      }
    } finally {
      try {
        await _closeNative();
      } on Object catch (error, stack) {
        _cleanupFailure = error;
        if (!_abandoned && !reportedFailure) {
          _controller.addError(
            _failure(
              'terminal_cleanup_failed',
              'The terminal could not be closed.',
            ),
            stack,
          );
          reportedFailure = true;
        }
      }
      if (_closing && _handle == null && !_abandoned && !reportedFailure) {
        _controller.addError(
          _failure(
            'terminal_provider_closed',
            'The provider closed before terminal startup completed.',
          ),
        );
      }
      // A failed native cleanup continues to consume a bounded admission slot;
      // releasing it would allow repeated failures to leak unlimited children.
      if (_cleanupFailure == null) {
        owner._handles.remove(_handle);
        owner._active.remove(this);
      }
      _producerClosed = true;
      unawaited(_controller.close());
      _finished.complete();
    }
  }

  Future<void> _emitText(String text) async {
    for (var offset = 0; offset < text.length;) {
      await _waitForCredit();
      if (_closing) return;
      if (_paused) continue;
      var end = min(offset + environmentTerminalTextLimit, text.length);
      if (end < text.length &&
          text.codeUnitAt(end - 1) >= 0xd800 &&
          text.codeUnitAt(end - 1) <= 0xdbff) {
        end--;
      }
      _controller.add(
        EnvironmentTerminalEvent(
          kind: EnvironmentTerminalEventKind.output,
          opened: null,
          output: text.substring(offset, end),
          completed: null,
        ),
      );
      offset = end;
    }
  }

  Future<void> _waitForCredit() async {
    while (_paused && !_closing) {
      final credit = _credit = Completer<void>();
      await credit.future;
    }
  }

  void _wake() {
    final credit = _credit;
    _credit = null;
    if (credit != null && !credit.isCompleted) credit.complete();
  }
}

final class _DecodedText implements Sink<String> {
  String _text = '';
  @override
  void add(String data) => _text += data;
  @override
  void close() {}
  String take() {
    final text = _text;
    _text = '';
    return text;
  }
}

// Keep the same allowlist as foreground_process.dart, with terminal-specific TERM.
Map<String, String> _childEnvironment(
  Directory directory,
  Map<String, String> parent,
) => <String, String>{
  for (final entry in parent.entries)
    if (const <String>{
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
        }.contains(entry.key) ||
        entry.key.startsWith('LC_'))
      entry.key: entry.value,
  'PATH': parent['PATH']?.isNotEmpty == true
      ? parent['PATH']!
      : '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
  'PWD': directory.path,
  'TERM': 'xterm-256color',
};

Future<String> _resolveExecutable(
  String program,
  Directory directory,
  String path,
) async {
  if (program.isEmpty ||
      program.contains('\u0000') ||
      program.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff)) {
    throw _failure(
      'terminal_executable_not_found',
      'The terminal executable is unavailable.',
    );
  }
  final candidates = program.contains('/')
      ? [program.startsWith('/') ? program : '${directory.path}/$program']
      : [
          for (final entry in path.split(':'))
            '${entry.startsWith('/') ? entry : '${directory.path}/$entry'}/$program',
        ];
  for (final candidate in candidates) {
    final stat = await FileStat.stat(candidate);
    if (stat.type == FileSystemEntityType.file && stat.mode & 0x49 != 0) {
      // Preserve argv[0] semantics for shell modes and multicall symlinks.
      return candidate;
    }
  }
  throw _failure(
    'terminal_executable_not_found',
    'The terminal executable is unavailable.',
  );
}

final class _NativeTerminalDriver implements GitTerminalDriver {
  const _NativeTerminalDriver(this.helperPath);
  final String? helperPath;

  @override
  Future<void> prepare() async {
    final path = helperPath;
    if (!Platform.isLinux ||
        Abi.current() != Abi.linuxX64 ||
        path == null ||
        !path.startsWith('/') ||
        path.contains('\u0000')) {
      throw _unavailable();
    }
    final stat = await FileStat.stat(path);
    if (stat.type != FileSystemEntityType.file || stat.mode & 0x49 == 0) {
      throw _unavailable();
    }
  }

  @override
  Future<GitTerminalSession> start({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    required Map<String, String> environment,
    required EnvironmentTerminalDimensions dimensions,
  }) async {
    try {
      return _NativeTerminalSession(
        await GitPtySession.start(
          helperPath: helperPath!,
          executable: executable,
          arguments: arguments,
          workingDirectory: workingDirectory,
          environment: environment,
          rows: dimensions.rows,
          columns: dimensions.columns,
        ),
      );
    } on ProcessException {
      // Preparation is deliberately lazy; a missing/inaccessible helper cannot
      // disable filesystem or foreground operations during provider construction.
      throw _unavailable();
    } on UnsupportedError {
      throw _unavailable();
    }
  }

  EnvironmentFailure _unavailable() => _failure(
    environmentTerminalUnavailableCode,
    'A prepared executable PTY helper on Linux x64 is required.',
  );
}

final class _NativeTerminalSession implements GitTerminalSession {
  const _NativeTerminalSession(this.native);
  final GitPtySession native;

  @override
  Future<Uint8List?> read() => native.read();
  @override
  Future<int> get exitCode => native.exitCode;
  @override
  Future<void> write(Uint8List bytes) => native.write(bytes);
  @override
  Future<void> resize(EnvironmentTerminalDimensions dimensions) =>
      native.resize(rows: dimensions.rows, columns: dimensions.columns);
  @override
  Future<void> close() => native.close();
}

EnvironmentFailure _failure(String code, String message) => EnvironmentFailure(
  code: code,
  message: message,
  details: const <String, Object?>{},
);
