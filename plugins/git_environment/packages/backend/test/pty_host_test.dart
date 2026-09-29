import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

import '../../../../../tools/git_pty_artifact.dart';

void main() {
  if (!Platform.isLinux || Abi.current() != Abi.linuxX64) {
    test('Linux x64 PTY proof', () {}, skip: 'Requires Linux x64 and devpts.');
    return;
  }
  late Directory artifacts;
  late String repository;
  late String runtime;
  late File helper;
  late File faultHelper;
  late File child;
  late File hostAot;
  late File backendAot;
  late PluginBackendHost host;
  late PluginBackendConnection backend;
  late PluginBackendConnection peer;

  setUpAll(() async {
    expect(Platform.version.split(' ').first, '3.10.9');
    repository = Directory.current.parent.parent.parent.parent.path;
    artifacts = await Directory.systemTemp.createTemp('adele-pty-proof-');
    helper = File('${artifacts.path}/git-pty-helper');
    faultHelper = File('${artifacts.path}/git-pty-helper-io-faults');
    child = File('${artifacts.path}/pty-child');
    hostAot = File('${artifacts.path}/host.aot');
    backendAot = File('${artifacts.path}/pty-backend.aot');
    final dart = Platform.resolvedExecutable;
    runtime = '${File(dart).parent.path}/dartaotruntime';
    await prepareGitPtyHelper(
      repositoryRoot: Directory(repository),
      output: helper,
    );
    await _run('cc', [
      '-std=c11',
      '-O2',
      '-Wall',
      '-Wextra',
      '-Werror',
      '$repository/plugins/git_environment/packages/backend/test/fixtures/pty_child.c',
      '-o',
      child.path,
    ]);
    await _run('cc', [
      '-std=c11',
      '-O2',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-DPTY_IO_FAULTS',
      '-Wl,--wrap=read',
      '-Wl,--wrap=write',
      '$repository/plugins/git_environment/packages/backend/native/git_pty_helper.c',
      '$repository/plugins/git_environment/packages/backend/test/fixtures/pty_child.c',
      '-o',
      faultHelper.path,
      '-lutil',
    ]);
    await Future.wait([
      _run(dart, [
        'compile',
        'aot-snapshot',
        '$repository/packages/plugin_backend_host/bin/adele_backend_host.dart',
        '-o',
        hostAot.path,
      ]),
      _run(dart, [
        'compile',
        'aot-snapshot',
        '$repository/plugins/git_environment/packages/backend/test/fixtures/pty_backend.dart',
        '-o',
        backendAot.path,
      ]),
    ]);
  });

  tearDownAll(() async => artifacts.delete(recursive: true));

  setUp(() async {
    host = await PluginBackendHost.start(
      dartaotruntimeExecutable: runtime,
      hostArtifactPath: hostAot.path,
      environment: {'ADELE_PTY_SENTINEL': 'host-only', 'PATH': '/no-compilers'},
    );
    backend = await host.startPlugin(
      pluginId: 'pty-proof',
      artifactUri: backendAot.uri,
      arguments: [helper.path],
      startupArgumentsOnly: true,
    );
    peer = await host.startPlugin(
      pluginId: 'pty-peer',
      artifactUri: backendAot.uri,
      arguments: [helper.path],
      startupArgumentsOnly: true,
    );
  });

  tearDown(() async => host.close());

  Future<int> open({
    String? executable,
    List<String> arguments = const [],
    String? helperPath,
  }) async =>
      (await backend.request('open', {
            'executable': executable ?? child.path,
            'arguments': arguments,
            'cwd': artifacts.path,
            'environment': {
              'PATH': '/usr/bin:/bin',
              'TERM': 'xterm-256color',
              'PS1': 'PTY-PROMPT> ',
            },
            'helper': ?helperPath,
          }))!
          as int;

  Future<void> write(String text) async {
    await backend.request('write', {'bytes': utf8.encode(text)});
  }

  test('independent AOT isolate groups own a real controlling PTY', () async {
    final before = Map<String, Object?>.from(
      (await peer.request('probe', {}))! as Map,
    );
    expect(before, containsPair('ordinaryExit', 23));
    expect(before, containsPair('sentinel', 'host-only'));
    final hostPid = before['pid']! as int;
    expect(await backend.request('probe', {}), before);
    final processBefore = await _processIdentity(hostPid);
    final childPid = await open();
    final text = await _readUntil(backend, 'STDERR-MERGED\r\n');
    expect(text, contains('TTY=1,1,1 CTTY=1'));
    expect(text, contains('\u001b[31m\u2603\u001b[0m'));
    expect(text, contains('STDERR-MERGED'));
    expect(
      text,
      contains('SID=$childPid PID=$childPid PGID=$childPid FG=$childPid'),
    );
    expect(text, contains('CWD=${artifacts.path} TERM=xterm-256color'));
    final identity = await _processIdentity(childPid);
    final helperIdentity = await _processIdentity(identity.parent);
    expect(helperIdentity.parent, hostPid);
    expect(identity.parent, isNot(hostPid));

    await write('size\n');
    expect(await _readUntil(backend, 'SIZE=24,80'), contains('SIZE=24,80'));
    await backend.request('resize', {'rows': 43, 'columns': 117});
    await write('size\n');
    expect(await _readUntil(backend, 'SIZE=43,117'), contains('SIZE=43,117'));
    await backend.request('resize', {'rows': 2000, 'columns': 1000});
    await write('size\n');
    expect(
      await _readUntil(backend, 'SIZE=2000,1000'),
      contains('SIZE=2000,1000'),
    );
    await write('hello-\u2603\n');
    expect(
      await _readUntil(backend, 'RECEIVED:hello-\u2603'),
      contains('RECEIVED:hello-\u2603'),
    );
    expect(await peer.request('probe', {}), before);
    expect(await _processIdentity(hostPid), processBefore);

    await write('exit\n');
    expect(await _readUntil(backend, 'FINAL'), contains('FINAL'));
    expect(await backend.request('exit', {}), 37);
    while (await backend.request('read', {}) != null) {}
    await backend.request('close', {});
    await backend.request('close', {});
    expect(await Directory('/proc/$childPid').exists(), isFalse);
    expect(await Directory('/proc/${identity.parent}').exists(), isFalse);
    expect(await peer.request('probe', {}), before);
  });

  test(
    'close reaps an ordinary foreground job in a separate process group',
    () async {
      final shellPid = await open(
        executable: '/bin/bash',
        arguments: ['--noprofile', '--norc', '-i'],
      );
      await _readUntil(backend, 'PTY-PROMPT>');
      await write(
        "/bin/sh -c 'trap \"\" TERM HUP; printf \"JOB=%s\\n\" \"\$\$\"; exec /bin/sleep 60'\n",
      );
      final text = await _readUntil(backend, RegExp(r'JOB=\d+'));
      final jobPid = int.parse(RegExp(r'JOB=(\d+)').firstMatch(text)![1]!);
      final job = await _processIdentity(jobPid);
      expect(job.group, isNot(shellPid));
      expect(job.session, shellPid);
      expect(job.foreground, job.group);
      final helperPid = (await _processIdentity(shellPid)).parent;
      await backend.request('close', {});
      for (final pid in [shellPid, jobPid, helperPid]) {
        expect(
          await Directory('/proc/$pid').exists(),
          isFalse,
          reason: 'Leaked PID $pid',
        );
      }
      expect(
        (await peer.request('probe', {}))! as Map,
        containsPair('ordinaryExit', 23),
      );
    },
  );

  test('leader exit reaps its surviving ordinary foreground job', () async {
    final shellPid = await open(arguments: ['--foreground']);
    final helperPid = (await _processIdentity(shellPid)).parent;
    final text = await _readUntil(backend, '\n');
    final jobPid = int.parse(RegExp(r'JOB=(\d+)').firstMatch(text)![1]!);
    addTearDown(() async {
      // Failure-path cleanup is confined to this fixture's original session.
      try {
        final identity = await _processIdentity(jobPid);
        if (identity.session == shellPid && identity.group == jobPid) {
          Process.killPid(jobPid, ProcessSignal.sigkill);
        }
      } on FileSystemException {
        // Already reaped.
      }
    });
    final job = await _processIdentity(jobPid);
    expect(job.session, shellPid);
    expect(job.foreground, jobPid);
    expect(job.group, isNot(shellPid));
    // The foreground child releases its leader, then remains in that group
    // ignoring HUP/TERM. No setsid, daemonization, or external PID kill.
    await write('x');
    expect(
      await backend.request('exit', {}).timeout(const Duration(seconds: 3)),
      37,
    );
    await backend.request('close', {});
    for (final pid in [shellPid, jobPid, helperPid]) {
      expect(await Directory('/proc/$pid').exists(), isFalse);
    }
    expect(
      (await peer.request('probe', {}))! as Map,
      containsPair('ordinaryExit', 23),
    );
  });

  for (final faults in [false, true]) {
    test(
      'input progresses while the child writes amplified output${faults ? ' with short I/O and EINTR' : ''}',
      () async {
        final pid = await open(
          arguments: ['--duplex'],
          helperPath: faults ? faultHelper.path : null,
        );
        await _readUntil(backend, 'DUPLEX-READY');
        // Drain inside the AOT backend so RPC latency cannot itself cause overflow.
        expect(
          await backend
              .request('duplex', {})
              .timeout(const Duration(seconds: 8)),
          {'bytes': 3 * 16384 * 64, 'valid': true, 'exit': 38},
        );
        await backend.request('close', {});
        expect(await Directory('/proc/$pid').exists(), isFalse);
      },
    );
  }

  test(
    'concurrent close settles a blocked write and pending read without losing exit evidence',
    () async {
      final probe = (await peer.request('probe', {}))! as Map;
      final hostPid = probe['pid']! as int;
      final descriptors = await Directory('/proc/$hostPid/fd').list().length;
      final pid = await open();
      final helperPid = (await _processIdentity(pid)).parent;
      await _readUntil(backend, 'STDERR-MERGED\r\n');
      await write('block\n');
      await _readUntil(backend, 'BLOCKED\n');
      final read = expectLater(backend.request('read', {}), completion(isNull));
      final input = () async {
        for (var i = 0; i < 64; i++) {
          await backend.request('write', {
            'bytes': List<int>.filled(16384, 120),
          });
        }
        fail('A non-reading PTY accepted a MiB without backpressure.');
      }();
      final rejected = expectLater(input, throwsA(isA<PluginRemoteFailure>()));
      await _waitFor(() async {
        final pending = (await backend.request('pending', {}))! as Map;
        return pending['reading'] == true && pending['writing'] == true;
      });
      final before = await backend.request('pending', {});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await backend.request('pending', {}), before);
      await Future.wait([
        backend.request('close', {}),
        backend.request('close', {}),
        read,
        rejected,
      ]).timeout(const Duration(seconds: 3));
      expect(
        await backend.request('exit', {}),
        128 + ProcessSignal.sigterm.signalNumber,
      );
      for (final gone in [pid, helperPid]) {
        expect(await Directory('/proc/$gone').exists(), isFalse);
      }
      expect(await peer.request('probe', {}), probe);
      await _waitFor(
        () async =>
            await Directory('/proc/$hostPid/fd').list().length <= descriptors,
      );
    },
  );

  test('close interrupts an empty pending read', () async {
    final pid = await open(arguments: ['--gated-startup']);
    final helperPid = (await _processIdentity(pid)).parent;
    await _readUntil(backend, 'SENTINEL=absent\n');
    // Force startup bytes to arrive after the early marker, then drain them all.
    final startup = _readUntil(backend, 'STARTUP-DONE\n');
    await _waitFor(
      () async =>
          ((await backend.request('pending', {}))! as Map)['reading'] == true,
    );
    await write('s');
    expect(
      await startup,
      '\u001b[31m\u2603\u001b[0m\nSTDERR-MERGED\nSTARTUP-DONE\n',
    );
    final read = expectLater(backend.request('read', {}), completion(isNull));
    await _waitFor(
      () async =>
          ((await backend.request('pending', {}))! as Map)['reading'] == true,
    );
    await Future.wait([
      backend.request('close', {}),
      read,
    ]).timeout(const Duration(seconds: 3));
    expect(await backend.request('exit', {}), 143);
    for (final gone in [pid, helperPid]) {
      expect(await Directory('/proc/$gone').exists(), isFalse);
    }
  });

  test('close cleans up with paused consumption and a stopped child', () async {
    final pid = await open(arguments: ['--burst']);
    final helperPid = (await _processIdentity(pid)).parent;
    await _readUntil(backend, 'BURST-READY');
    await write('b');
    await _waitFor(() async {
      final stat = await File('/proc/$pid/stat').readAsString();
      return stat.substring(stat.lastIndexOf(')') + 2).startsWith('T ');
    });
    // No more reads: the finite 64 KiB burst stays below the overflow bound.
    await Future.wait([
      backend.request('close', {}),
      backend.request('close', {}),
    ]).timeout(const Duration(seconds: 3));
    for (final gone in [pid, helperPid]) {
      expect(await Directory('/proc/$gone').exists(), isFalse);
    }
    expect(
      (await peer.request('probe', {}))! as Map,
      containsPair('ordinaryExit', 23),
    );
  });

  for (final evidence in ['missing', 'truncated']) {
    test('$evidence exit frame is never a successful child exit', () async {
      final pid = await open(helperPath: child.path, arguments: [evidence]);
      final read = expectLater(
        backend.request('read', {}),
        throwsA(isA<PluginRemoteFailure>()),
      );
      final exit = expectLater(
        backend.request('exit', {}),
        throwsA(
          isA<PluginRemoteFailure>().having(
            (e) => e.message,
            'missing evidence',
            contains('without a complete result (0)'),
          ),
        ),
      );
      expect(Process.killPid(pid, ProcessSignal.sigusr1), isTrue);
      await Future.wait([read, exit]).timeout(const Duration(seconds: 3));
      await backend.request('close', {});
      expect(await Directory('/proc/$pid').exists(), isFalse);
      expect(
        (await peer.request('probe', {}))! as Map,
        containsPair('ordinaryExit', 23),
      );
    });
  }

  for (final cleanupFailed in [false, true]) {
    test(
      cleanupFailed
          ? 'close propagates cleanup failure even after an earlier transport error'
          : 'close succeeds after transport failure with confirmed cleanup',
      () async {
        final pid = await open(
          helperPath: child.path,
          arguments: [cleanupFailed ? 'cleanup-failed' : 'transport-clean'],
        );
        addTearDown(() async {
          try {
            await backend
                .request('close', {})
                .timeout(const Duration(seconds: 6));
          } on Object {
            // This stand-in has no descendants; its failed close is intentional.
          }
          await host.close(graceful: false);
        });
        final transportFailure = throwsA(
          isA<PluginRemoteFailure>().having(
            (e) => e.message,
            'transport error',
            contains('fixture transport failed'),
          ),
        );
        final read = expectLater(backend.request('read', {}), transportFailure);
        final exit = expectLater(backend.request('exit', {}), transportFailure);
        expect(Process.killPid(pid, ProcessSignal.sigusr1), isTrue);
        await Future.wait([read, exit]).timeout(const Duration(seconds: 3));
        for (var i = 0; i < 2; i++) {
          final close = backend.request('close', {});
          if (cleanupFailed) {
            await expectLater(
              close,
              throwsA(
                isA<PluginRemoteFailure>().having(
                  (e) => e.message,
                  'cleanup error',
                  contains('PTY cleanup did not complete (helper exit 126)'),
                ),
              ),
            );
          } else {
            await close;
          }
        }
        expect(await Directory('/proc/$pid').exists(), isFalse);
        expect(
          (await peer.request('probe', {}))! as Map,
          containsPair('ordinaryExit', 23),
        );
      },
    );
  }

  for (final code in [125, 126]) {
    test('child exit $code is not a helper cleanup failure', () async {
      final pid = await open(
        executable: '/bin/sh',
        arguments: ['-c', 'exit $code'],
      );
      expect(await backend.request('exit', {}), code);
      await backend.request('close', {});
      await backend.request('close', {});
      expect(await Directory('/proc/$pid').exists(), isFalse);
    });
  }

  test(
    'forced helper kill leaves close cleanup explicitly unconfirmed',
    () async {
      final pid = await open(
        helperPath: child.path,
        arguments: ['ignore-close'],
      );
      addTearDown(() async {
        try {
          await backend
              .request('close', {})
              .timeout(const Duration(seconds: 6));
        } on Object {
          // The stand-in ignores TERM but has no descendants to leak on KILL.
        }
        await host.close(graceful: false);
      });
      final exit = expectLater(
        backend.request('exit', {}),
        throwsA(isA<PluginRemoteFailure>()),
      );
      for (var i = 0; i < 2; i++) {
        await expectLater(
          backend.request('close', {}).timeout(const Duration(seconds: 5)),
          throwsA(
            isA<PluginRemoteFailure>().having(
              (e) => e.message,
              'unconfirmed cleanup',
              contains('PTY cleanup could not be confirmed (helper exit -9)'),
            ),
          ),
        );
      }
      await exit;
      expect(await Directory('/proc/$pid').exists(), isFalse);
      expect(
        (await peer.request('probe', {}))! as Map,
        containsPair('ordinaryExit', 23),
      );
    },
  );

  test(
    'provider shutdown cleans up its PTY without retiring its peer',
    () async {
      final pid = await open();
      await _readUntil(backend, 'CTTY=1');
      await backend.close();
      expect(await Directory('/proc/$pid').exists(), isFalse);
      expect(
        (await peer.request('probe', {}))! as Map,
        containsPair('ordinaryExit', 23),
      );
    },
  );

  test(
    'bad prepared path and exec fail explicitly; shared host survives',
    () async {
      await expectLater(
        open(helperPath: '${artifacts.path}/missing-helper'),
        throwsA(isA<PluginRemoteFailure>()),
      );
      await expectLater(
        open(executable: '${artifacts.path}/missing-program'),
        throwsA(
          isA<PluginRemoteFailure>().having(
            (e) => e.message,
            'launch failure with successful cleanup',
            contains('exec/setup'),
          ),
        ),
      );
      final pid = await open();
      await _readUntil(backend, 'CTTY=1');
      await backend.request('close', {});
      expect(await Directory('/proc/$pid').exists(), isFalse);
      expect(
        (await peer.request('probe', {}))! as Map,
        containsPair('ordinaryExit', 23),
      );
    },
  );

  test(
    'shared-host loss closes helper pipes and terminates the terminal',
    () async {
      final pid = await open();
      await _readUntil(backend, 'CTTY=1');
      await host.close(graceful: false);
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (await Directory('/proc/$pid').exists() &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(await Directory('/proc/$pid').exists(), isFalse);
    },
  );

  test(
    'a child that stops reading cannot hold an input write indefinitely',
    () async {
      final pid = await open();
      await _readUntil(backend, 'SENTINEL=absent');
      await write('block\n');
      await _readUntil(backend, 'BLOCKED');
      final blocked = () async {
        for (var i = 0; i < 64; i++) {
          await backend.request('write', {
            'bytes': List<int>.filled(16384, 120),
          });
        }
        fail('A non-reading PTY accepted a MiB without backpressure.');
      }();
      await expectLater(
        blocked.timeout(const Duration(seconds: 8)),
        throwsA(isA<PluginRemoteFailure>()),
      );
      await backend.request('close', {});
      expect(await Directory('/proc/$pid').exists(), isFalse);
      expect(
        (await peer.request('probe', {}))! as Map,
        containsPair('ordinaryExit', 23),
      );
    },
  );

  test(
    'bounded input and geometry reject; unread output fails and cleans up',
    () async {
      final pid = await open();
      await _readUntil(backend, 'SENTINEL=absent');
      await expectLater(
        backend.request('write', {'bytes': List<int>.filled(16385, 120)}),
        throwsA(isA<PluginRemoteFailure>()),
      );
      await expectLater(
        backend.request('resize', {'rows': 0, 'columns': 80}),
        throwsA(isA<PluginRemoteFailure>()),
      );
      await expectLater(
        backend.request('resize', {'rows': 2001, 'columns': 80}),
        throwsA(isA<PluginRemoteFailure>()),
      );
      await expectLater(
        backend.request('resize', {'rows': 24, 'columns': 1001}),
        throwsA(isA<PluginRemoteFailure>()),
      );
      await write('flood\n');
      await expectLater(
        backend.request('exit', {}),
        throwsA(
          isA<PluginRemoteFailure>().having(
            (e) => e.message,
            'overflow',
            contains('unread bytes'),
          ),
        ),
      );
      await backend.request('close', {});
      expect(await Directory('/proc/$pid').exists(), isFalse);
      expect(
        (await peer.request('probe', {}))! as Map,
        containsPair('ordinaryExit', 23),
      );
    },
  );
}

Future<void> _waitFor(Future<bool> Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!await predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Fixture did not reach its handshake.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _run(String program, List<String> args) async {
  final result = await Process.run(program, args);
  if (result.exitCode != 0) {
    throw StateError('$program failed: ${result.stdout}\n${result.stderr}');
  }
}

Future<String> _readUntil(
  PluginBackendConnection backend,
  Pattern marker,
) async {
  final bytes = <int>[];
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(deadline)) {
    final chunk = await backend
        .request('read', {})
        .timeout(const Duration(seconds: 8));
    if (chunk == null) break;
    bytes.addAll((chunk as List).cast<int>());
    if (bytes.length > 256 * 1024) {
      throw StateError('Test output limit exceeded.');
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    if (text.contains(marker)) return text;
  }
  throw StateError(
    'Missing $marker in ${utf8.decode(bytes, allowMalformed: true)}',
  );
}

Future<({int parent, int group, int session, int foreground})> _processIdentity(
  int pid,
) async {
  final stat = await File('/proc/$pid/stat').readAsString();
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  return (
    parent: int.parse(fields[1]),
    group: int.parse(fields[2]),
    session: int.parse(fields[3]),
    foreground: int.parse(fields[5]),
  );
}
