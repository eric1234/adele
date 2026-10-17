@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:git_backend/git_backend.dart';
import 'package:git_backend/src/foreground_process.dart';
import 'package:test/test.dart';

import 'fixtures/buffered_process_child.dart' show binaryStderr;

final _fixturePath = File(
  'test/fixtures/buffered_process_child.dart',
).absolute.path;
final _environmentId = EnvironmentId('buffered-process-test');

void main() {
  late Directory root;
  late WorktreeEnvironment environment;
  late GitBufferedProcessSupervisor supervisor;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('adele-buffered-process-');
    environment = WorktreeEnvironment(root);
    supervisor = GitBufferedProcessSupervisor();
  });

  tearDown(() async {
    await supervisor.close();
    await root.delete(recursive: true);
  });

  Future<EnvironmentBufferedProcessResult> run(
    List<String> arguments, {
    List<int> input = const [],
    String cwd = '',
    int timeout = 10,
  }) => supervisor.run(
    environmentId: _environmentId,
    environment: environment,
    request: _request(arguments, input: input, cwd: cwd, timeout: timeout),
  );

  test(
    'preserves binary input, EOF and binary outputs without decoding',
    () async {
      for (final input in [
        <int>[],
        <int>[0, 255, 128, 192, 13, 10, 13, 27, 91, 50, 74, 0, 4],
        _bytes(65537),
      ]) {
        final result = await run(['echo'], input: input);
        expect(result.exitCode, 0);
        expect(_stdout(result), input);
        expect(_stderr(result), binaryStderr);
      }
      expect(supervisor.retainedOutputBytes, 0);
    },
  );

  test(
    'empty output is complete empty base64; nonzero exits remain data',
    () async {
      final empty = await run(['empty']);
      expect(empty.exitCode, 0);
      expect(empty.stdoutBase64, '');
      expect(empty.stderrBase64, '');
      for (final code in [23, 126, 127]) {
        final result = await run(['echo', '$code'], input: [0, 255]);
        expect(result.exitCode, code);
        expect(_stdout(result), [0, 255]);
        expect(_stderr(result), binaryStderr);
      }
    },
  );

  test(
    'collects both maximum outputs concurrently with maximum stdin',
    () async {
      final input = _bytes(environmentBufferedProcessStdinLimit);
      final result = await run([
        'outputs',
        '$environmentBufferedProcessStdoutLimit',
        '$environmentBufferedProcessStderrLimit',
        '${input.length}',
      ], input: input);
      expect(result.exitCode, 0);
      expect(_stdout(result), _bytes(environmentBufferedProcessStdoutLimit));
      expect(_stderr(result), _bytes(environmentBufferedProcessStderrLimit));
      expect(supervisor.retainedOutputBytes, 0);
    },
  );

  for (final pipe in ['stdout', 'stderr']) {
    test('one byte above $pipe bound fails without a partial result', () async {
      await expectLater(
        run([
          'outputs',
          '${pipe == 'stdout' ? environmentBufferedProcessStdoutLimit + 1 : 0}',
          '${pipe == 'stderr' ? environmentBufferedProcessStderrLimit + 1 : 0}',
        ]),
        throwsA(
          _failure(
            'process_output_overflow',
          ).having((error) => error.details['stream'], 'stream', pipe),
        ),
      );
      expect(supervisor.retainedOutputBytes, 0);
    });
  }

  test(
    'input refusal prevents success even when the child exits zero',
    () async {
      await expectLater(
        run(['refuse'], input: _bytes(environmentBufferedProcessStdinLimit)),
        throwsA(_failure('process_stdin_failed')),
      );
    },
  );

  test(
    'a pipe read error never publishes collected output as a result',
    () async {
      final failing = GitBufferedProcessSupervisor(
        startProcess:
            (
              executable,
              arguments, {
              required workingDirectory,
              required environment,
            }) async {
              final process = await Process.start(
                executable,
                arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                includeParentEnvironment: false,
                runInShell: false,
              );
              return _ProcessView(
                process,
                output: process.stdout.transform(
                  StreamTransformer<List<int>, List<int>>.fromHandlers(
                    handleData: (bytes, sink) {
                      sink.add(bytes);
                      sink.addError(
                        const FileSystemException('injected read failure'),
                      );
                    },
                  ),
                ),
              );
            },
      );
      addTearDown(failing.close);
      await expectLater(
        failing.run(
          environmentId: _environmentId,
          environment: environment,
          request: _request(['outputs', '9', '0']),
        ),
        throwsA(_failure('process_output_failed')),
      );
      expect(failing.retainedOutputBytes, 0);
    },
  );

  for (final timeOut in [false, true]) {
    test(
      'stdin settlement ${timeOut ? 'is deadline-bounded' : 'precedes successful completion'}',
      () async {
        final inputClose = Completer<void>();
        final native = Completer<Process>();
        final gated = GitBufferedProcessSupervisor(
          startProcess:
              (
                executable,
                arguments, {
                required workingDirectory,
                required environment,
              }) async {
                final process = await Process.start(
                  executable,
                  arguments,
                  workingDirectory: workingDirectory,
                  environment: environment,
                  includeParentEnvironment: false,
                  runInShell: false,
                );
                native.complete(process);
                return _ProcessView(
                  process,
                  input: IOSink(
                    _DelayedInputClose(process.stdin, inputClose.future),
                  ),
                );
              },
        );
        addTearDown(() async {
          if (!inputClose.isCompleted) inputClose.complete();
          await gated.close();
        });
        var completed = false;
        final result = gated.run(
          environmentId: _environmentId,
          environment: environment,
          request: _request(['empty'], timeout: timeOut ? 3 : 10),
        );
        final checked = timeOut
            ? expectLater(
                result,
                throwsA(
                  _failure('process_timed_out').having(
                    (error) => error.details['cleanupIncomplete'],
                    'cleanupIncomplete',
                    true,
                  ),
                ),
              )
            : result.then((value) {
                completed = true;
                expect(value.exitCode, 0);
                expect(value.stdoutBase64, '');
              });
        expect(await (await native.future).exitCode, 0);
        if (timeOut) await checked;
        expect(completed, isFalse);
        expect(gated.activeExecutionCount, 1);
        inputClose.complete();
        await checked;
        await gated.close();
        expect(gated.activeExecutionCount, 0);
      },
    );
  }

  test(
    'uses confined canonical cwd, literal argv and child environment',
    () async {
      final nested = await Directory('${root.path}/nested').create();
      await Link('${root.path}/alias').create(nested.path);
      const arguments = ['a b', '*.dart', r'$HOME', '; false', '', '--literal'];
      final result = await run(['cwd', ...arguments], cwd: 'alias');
      final value =
          jsonDecode(utf8.decode(_stdout(result))) as Map<String, dynamic>;
      expect(value['cwd'], nested.path);
      expect(value['pwd'], nested.path);
      expect(value['term'], 'dumb');
      expect(value['arguments'], arguments);
      final childEnvironment = value['environment'] as Map<String, dynamic>;
      expect(childEnvironment, contains('PATH'));
      expect(
        childEnvironment.keys.any((key) => key.startsWith('ADELE_')),
        isFalse,
      );
      expect(
        childEnvironment.keys.any((key) => key.startsWith('GIT_')),
        isFalse,
      );
      expect(childEnvironment, isNot(contains('OPENAI_API_KEY')));
      expect(childEnvironment, isNot(contains('SSH_AUTH_SOCK')));
    },
  );

  test(
    'rejects traversal, absolute cwd, missing cwd and escaping symlinks',
    () async {
      await Link('${root.path}/escape').create(root.parent.path);
      for (final cwd in ['../', root.path, 'missing', 'escape']) {
        await expectLater(
          run(['empty'], cwd: cwd),
          throwsA(isA<EnvironmentFailure>()),
        );
        expect(supervisor.activeExecutionCount, 0);
      }
    },
  );

  test('missing and non-executable programs fail before spawn', () async {
    final nonExecutable = await File(
      '${root.path}/not-executable',
    ).writeAsString('no');
    for (final program in ['${root.path}/missing', nonExecutable.path]) {
      await expectLater(
        supervisor.run(
          environmentId: _environmentId,
          environment: environment,
          request: EnvironmentBufferedProcessRequest(
            program: program,
            arguments: [],
            relativeWorkingDirectory: '',
            timeoutSeconds: 5,
            stdinBase64: '',
          ),
        ),
        throwsA(
          _failure(
            program == nonExecutable.path
                ? 'process_start_failed'
                : 'process_executable_not_found',
          ),
        ),
      );
    }
  });

  for (final timeOut in [false, true]) {
    test(
      'pending cwd resolution is fenced by ${timeOut ? 'timeout' : 'shutdown'}',
      () async {
        final resolving = Completer<void>();
        final gate = Completer<void>();
        final nativeZone = Zone.current;
        var starts = 0;
        final delayed = GitBufferedProcessSupervisor(
          startProcess:
              (
                executable,
                arguments, {
                required workingDirectory,
                required environment,
              }) async {
                starts++;
                throw StateError('A fenced setup must never start a process.');
              },
        );
        addTearDown(() async {
          if (!gate.isCompleted) gate.complete();
          await delayed.close();
        });
        await IOOverrides.runZoned(
          () async {
            final failed = expectLater(
              delayed.run(
                environmentId: _environmentId,
                environment: environment,
                request: _request(['empty'], timeout: 1),
              ),
              throwsA(
                _failure(
                  timeOut ? 'process_timed_out' : 'process_provider_closed',
                ),
              ),
            );
            await resolving.future;
            final Future<void> closing;
            if (timeOut) {
              await failed;
              expect(delayed.activeExecutionCount, 1);
              closing = delayed.close();
            } else {
              closing = delayed.close();
            }
            gate.complete();
            await closing;
            await failed;
          },
          fseGetType: (path, followLinks) async {
            if (!resolving.isCompleted) resolving.complete();
            await gate.future;
            return nativeZone.run(
              () => FileSystemEntity.type(path, followLinks: followLinks),
            );
          },
        );
        expect(starts, 0);
        expect(delayed.activeExecutionCount, 0);
      },
    );
  }

  test('native start exceptions are typed and release admission', () async {
    final failing = GitBufferedProcessSupervisor(
      startProcess:
          (
            executable,
            arguments, {
            required workingDirectory,
            required environment,
          }) async {
            throw ProcessException(executable, arguments, 'test start failure');
          },
    );
    addTearDown(failing.close);
    await expectLater(
      failing.run(
        environmentId: _environmentId,
        environment: environment,
        request: _request(['empty']),
      ),
      throwsA(_failure('process_start_failed')),
    );
    expect(failing.activeExecutionCount, 0);
  });

  test(
    'timeout kills the leader and TERM-resistant ordinary descendant',
    () async {
      final pidFile = File('${root.path}/timeout-pids');
      final outcome = expectLater(
        run(['tree', pidFile.path], timeout: 5),
        throwsA(_failure('process_timed_out')),
      );
      final pids = await _readPids(pidFile);
      addTearDown(() => _kill(pids));
      await outcome;
      await _expectDead(pids);
    },
  );

  for (final pipe in ['stdout', 'stderr']) {
    test('$pipe overflow kills the entire owned process group', () async {
      final pidFile = File('${root.path}/overflow-pids');
      final outcome = expectLater(
        run(['overflow-tree', pidFile.path, pipe]),
        throwsA(_failure('process_output_overflow')),
      );
      final pids = await _readPids(pidFile);
      addTearDown(() => _kill(pids));
      await outcome;
      await _expectDead(pids);
      expect(supervisor.retainedOutputBytes, 0);
    });
  }

  test(
    'normal leader exit cleans descendants and waits for inherited pipe EOF',
    () async {
      final pidFile = File('${root.path}/exit-pids');
      final resultFuture = run(['exit-tree', pidFile.path]);
      final pids = await _readPids(pidFile);
      addTearDown(() => _kill(pids));
      final result = await resultFuture;
      expect(result.exitCode, 23);
      expect(result.stdoutBase64, '');
      expect(result.stderrBase64, '');
      await _expectDead(pids);
    },
  );

  test(
    'deadline still covers pipe EOF after leader exit with escaped holder',
    () async {
      final pidFile = File('${root.path}/escaped-pids');
      final watch = Stopwatch()..start();
      final outcome = expectLater(
        run(['escaped-tree', pidFile.path], timeout: 5),
        throwsA(_failure('process_timed_out')),
      );
      final pids = await _readPids(pidFile);
      addTearDown(() => _kill(pids));
      await outcome;
      expect(watch.elapsed, lessThan(const Duration(seconds: 6)));
      expect(await _isAlive(pids.first), isFalse);
      expect(
        await _isAlive(pids.last),
        isTrue,
        reason: 'setsid escape is not a sandbox guarantee',
      );
      expect(supervisor.retainedOutputBytes, 0);
    },
  );

  test(
    'shutdown terminates active work, fences admission and is idempotent',
    () async {
      final pidFile = File('${root.path}/shutdown-pids');
      final outcome = expectLater(
        run(['tree', pidFile.path]),
        throwsA(_failure('process_provider_closed')),
      );
      final second = expectLater(
        run(['wait']),
        throwsA(_failure('process_provider_closed')),
      );
      final pids = await _readPids(pidFile);
      addTearDown(() => _kill(pids));
      final closing = supervisor.close();
      expect(identical(closing, supervisor.close()), isTrue);
      await expectLater(
        run(['empty']),
        throwsA(_failure('process_provider_closed')),
      );
      await closing;
      await Future.wait([outcome, second]);
      await _expectDead(pids);
      expect(supervisor.activeExecutionCount, 0);
    },
  );

  test(
    'empty stdin permits a process that exited before start returned',
    () async {
      final gate = _LateStart(startBeforeRelease: true);
      final lateSupervisor = GitBufferedProcessSupervisor(
        startProcess: gate.start,
      );
      addTearDown(() async {
        gate.release();
        await lateSupervisor.close();
      });
      final resultFuture = lateSupervisor.run(
        environmentId: _environmentId,
        environment: environment,
        request: _request(['refuse']),
      );
      final process = await gate.process.future;
      expect(await process.exitCode, 0);
      gate.release();
      final result = await resultFuture;
      expect(result.exitCode, 0);
      expect(result.stdoutBase64, '');
      expect(result.stderrBase64, '');
    },
  );

  test('timeout retains and terminates a late Process.start result', () async {
    final gate = _LateStart();
    final lateSupervisor = GitBufferedProcessSupervisor(
      startProcess: gate.start,
    );
    addTearDown(() async {
      gate.release();
      await lateSupervisor.close();
    });
    final failed = expectLater(
      lateSupervisor.run(
        environmentId: _environmentId,
        environment: environment,
        request: _request(['wait'], timeout: 1),
      ),
      throwsA(_failure('process_timed_out')),
    );
    await gate.entered.future;
    await failed;
    expect(lateSupervisor.activeExecutionCount, 1);
    gate.release();
    final process = await gate.process.future;
    await process.exitCode.timeout(const Duration(seconds: 3));
    await lateSupervisor.close();
    expect(lateSupervisor.activeExecutionCount, 0);
    expect(await _isAlive(process.pid), isFalse);
  });

  test(
    'shutdown is bounded but keeps ownership of a still-pending start',
    () async {
      final gate = _LateStart();
      final lateSupervisor = GitBufferedProcessSupervisor(
        startProcess: gate.start,
      );
      addTearDown(gate.release);
      final failed = expectLater(
        lateSupervisor.run(
          environmentId: _environmentId,
          environment: environment,
          request: _request(['wait']),
        ),
        throwsA(_failure('process_provider_closed')),
      );
      await gate.entered.future;
      await expectLater(
        lateSupervisor.close(),
        throwsA(_failure('process_cleanup_failed')),
      );
      await failed;
      expect(lateSupervisor.activeExecutionCount, 1);
      gate.release();
      final process = await gate.process.future;
      await process.exitCode.timeout(const Duration(seconds: 3));
      await _until(() => lateSupervisor.activeExecutionCount == 0);
      expect(await _isAlive(process.pid), isFalse);
      await expectLater(
        lateSupervisor.close(),
        throwsA(_failure('process_cleanup_failed')),
      );
    },
  );

  test(
    'late already-completed process cannot publish success after timeout',
    () async {
      final gate = _LateStart(startBeforeRelease: true);
      final lateSupervisor = GitBufferedProcessSupervisor(
        startProcess: gate.start,
      );
      addTearDown(() async {
        gate.release();
        await lateSupervisor.close();
      });
      final failed = expectLater(
        lateSupervisor.run(
          environmentId: _environmentId,
          environment: environment,
          request: _request(['outputs', '9', '7'], timeout: 1),
        ),
        throwsA(_failure('process_timed_out')),
      );
      final process = await gate.process.future;
      await process.stdin.close();
      expect(await process.exitCode, 0);
      await failed;
      expect(lateSupervisor.activeExecutionCount, 1);
      gate.release();
      await lateSupervisor.close();
      expect(lateSupervisor.activeExecutionCount, 0);
      expect(lateSupervisor.retainedOutputBytes, 0);
    },
  );

  test(
    'provider uses only the exact live Environment and closes buffered work',
    () async {
      final provider = GitWorktreeEnvironmentProvider();
      addTearDown(provider.close);
      final firstId = EnvironmentId('first');
      final secondId = EnvironmentId('second');
      final first = await Directory('${root.path}/first').create();
      final second = await Directory('${root.path}/second').create();
      provider.liveObjects.bind(firstId, WorktreeEnvironment(first));
      provider.liveObjects.bind(secondId, WorktreeEnvironment(second));
      for (final (id, directory) in [(firstId, first), (secondId, second)]) {
        final result = await provider.runBufferedProcess(id, _request(['cwd']));
        expect(
          (jsonDecode(utf8.decode(_stdout(result))) as Map)['cwd'],
          directory.path,
        );
      }
      await expectLater(
        provider.runBufferedProcess(
          EnvironmentId('missing'),
          _request(['empty']),
        ),
        throwsA(_failure('environment_not_live')),
      );
      final pidFile = File('${root.path}/provider-pids');
      final failed = expectLater(
        provider.runBufferedProcess(secondId, _request(['tree', pidFile.path])),
        throwsA(_failure('process_provider_closed')),
      );
      final pids = await _readPids(pidFile);
      addTearDown(() => _kill(pids));
      await provider.close();
      await failed;
      await _expectDead(pids);
      expect(provider.liveObjects.length, 0);
      expect(await first.exists(), isTrue);
      expect(await second.exists(), isTrue);
      await expectLater(
        provider.runBufferedProcess(firstId, _request(['empty'])),
        throwsA(_failure('environment_provider_closed')),
      );
    },
  );
}

EnvironmentBufferedProcessRequest _request(
  List<String> arguments, {
  List<int> input = const [],
  String cwd = '',
  int timeout = 10,
}) => EnvironmentBufferedProcessRequest(
  program: Platform.resolvedExecutable,
  arguments: [_fixturePath, ...arguments],
  relativeWorkingDirectory: cwd,
  timeoutSeconds: timeout,
  stdinBase64: encodeEnvironmentProcessBytes(
    input,
    maximumBytes: environmentBufferedProcessStdinLimit,
  ),
);

List<int> _stdout(EnvironmentBufferedProcessResult result) =>
    decodeEnvironmentProcessBytes(
      result.stdoutBase64,
      maximumBytes: environmentBufferedProcessStdoutLimit,
    );

List<int> _stderr(EnvironmentBufferedProcessResult result) =>
    decodeEnvironmentProcessBytes(
      result.stderrBase64,
      maximumBytes: environmentBufferedProcessStderrLimit,
    );

Uint8List _bytes(int count) =>
    Uint8List.fromList(List<int>.generate(count, (i) => i % 256));

TypeMatcher<EnvironmentFailure> _failure(String code) =>
    isA<EnvironmentFailure>().having((error) => error.code, 'code', code);

Future<void> _until(FutureOr<bool> Function() condition) async {
  final watch = Stopwatch()..start();
  while (!await condition()) {
    if (watch.elapsed > const Duration(seconds: 5)) {
      fail('Condition did not settle.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<List<int>> _readPids(File file) async {
  await _until(
    () async =>
        await file.exists() &&
        (await file.readAsString()).trim().split(' ').length == 2,
  );
  return (await file.readAsString()).split(' ').map(int.parse).toList();
}

Future<bool> _isAlive(int pid) async {
  try {
    final stat = await File('/proc/$pid/stat').readAsString();
    return stat.substring(stat.lastIndexOf(')') + 2).split(' ').first != 'Z';
  } on FileSystemException {
    return false;
  }
}

Future<void> _expectDead(List<int> pids) async {
  for (final pid in pids) {
    await _until(() async => !await _isAlive(pid));
  }
}

void _kill(List<int> pids) {
  for (final pid in pids) {
    Process.killPid(pid, ProcessSignal.sigkill);
  }
}

final class _LateStart {
  _LateStart({this.startBeforeRelease = false});

  final bool startBeforeRelease;
  final entered = Completer<void>();
  final process = Completer<Process>();
  final _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  Future<Process> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
  }) async {
    entered.complete();
    if (!startBeforeRelease) await _gate.future;
    final child = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
    );
    process.complete(child);
    if (startBeforeRelease) await _gate.future;
    return child;
  }
}

final class _ProcessView implements Process {
  _ProcessView(this.process, {IOSink? input, Stream<List<int>>? output})
    : stdin = input ?? process.stdin,
      stdout = output ?? process.stdout;

  final Process process;
  @override
  final IOSink stdin;
  @override
  final Stream<List<int>> stdout;
  @override
  Stream<List<int>> get stderr => process.stderr;
  @override
  Future<int> get exitCode => process.exitCode;
  @override
  int get pid => process.pid;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      process.kill(signal);
}

final class _DelayedInputClose implements StreamConsumer<List<int>> {
  _DelayedInputClose(this.sink, this.gate);

  final IOSink sink;
  final Future<void> gate;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await sink.addStream(stream);
  }

  @override
  Future<void> close() async {
    await sink.close();
    await gate;
  }
}
