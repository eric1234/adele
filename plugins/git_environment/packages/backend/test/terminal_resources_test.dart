import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:git_environment_backend/git_environment_backend.dart';
import 'package:git_environment_backend/src/terminal_resources.dart';
import 'package:test/test.dart';

import '../../../../../tools/git_pty_artifact.dart';

Future<void> main([List<String> arguments = const []]) async {
  if (arguments.isNotEmpty && arguments.first == '--terminal-env-probe') {
    await _environmentProbe(arguments[1], arguments[2]);
    return;
  }
  late Directory root;
  late WorktreeEnvironment environment;
  late _Driver driver;
  late GitTerminalSupervisor supervisor;
  final environmentId = EnvironmentId('one');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('adele-terminal-resources-');
    environment = WorktreeEnvironment(root);
    driver = _Driver();
    supervisor = GitTerminalSupervisor(driver: driver);
  });
  tearDown(() async {
    await supervisor.close();
    await root.delete(recursive: true);
  });

  Stream<EnvironmentTerminalEvent> open({
    EnvironmentId? id,
    String cwd = '',
    GitTerminalSupervisor? owner,
    String program = '/bin/sh',
  }) => (owner ?? supervisor).open(
    environmentId: id ?? environmentId,
    resolveEnvironment: () => environment,
    request: _request(cwd: cwd, program: program),
  );

  test(
    'lazy single owner, opened first, complete once and no reattachment',
    () async {
      final stream = open();
      expect(driver.prepares, 0);
      expect(driver.starts, 0);
      final events = _Events(stream);
      final handle = await events.handle;
      expect(handle, isNotEmpty);
      expect(driver.starts, 1);
      driver.sessions.single.output(
        utf8.encode('hello\r\n\u001b[31mred\u0000'),
      );
      driver.sessions.single.exit(23);
      await events.done;
      expect(events.errors, isEmpty);
      expect(events.events.first.kind, EnvironmentTerminalEventKind.opened);
      expect(events.text, 'hello\r\n\u001b[31mred\u0000');
      expect(
        events.events.last.completed!.termination,
        EnvironmentTerminalTermination.exited,
      );
      expect(events.events.last.completed!.exitCode, 23);
      expect(driver.sessions.single.closes, 1);
      expect(() => stream.listen((_) {}), throwsStateError);
      await supervisor.closeTerminal(environmentId, handle);
      await supervisor.closeTerminal(environmentId, handle);
      await expectLater(
        supervisor.write(environmentId, handle, 'x'),
        throwsA(_code('terminal_gone')),
      );
      await expectLater(
        supervisor.resize(environmentId, handle, _dimensions()),
        throwsA(_code('terminal_gone')),
      );
    },
  );

  test(
    'authority is exact Environment and generation, including retired handles',
    () async {
      final events = _Events(open());
      final handle = await events.handle;
      final otherId = EnvironmentId('two');
      final other = GitTerminalSupervisor(driver: _Driver());
      addTearDown(other.close);
      for (final owner in [supervisor, other]) {
        final id = identical(owner, supervisor) ? otherId : environmentId;
        await expectLater(
          owner.closeTerminal(id, handle),
          throwsA(_code('invalid_terminal_handle')),
        );
        await expectLater(
          owner.write(id, handle, 'x'),
          throwsA(_code('invalid_terminal_handle')),
        );
        await expectLater(
          owner.resize(id, handle, _dimensions()),
          throwsA(_code('invalid_terminal_handle')),
        );
      }
      await expectLater(
        supervisor.closeTerminal(environmentId, '1234'),
        throwsA(_code('invalid_terminal_handle')),
      );
      final forged = '${handle.substring(0, 33)}${'A' * 43}';
      await expectLater(
        supervisor.closeTerminal(environmentId, forged),
        throwsA(_code('invalid_terminal_handle')),
      );
      await supervisor.closeTerminal(environmentId, handle);
      await events.done;
      await expectLater(
        supervisor.closeTerminal(otherId, handle),
        throwsA(_code('invalid_terminal_handle')),
      );
      expect(
        events.events.last.completed!.termination,
        EnvironmentTerminalTermination.closed,
      );
      expect(events.events.last.completed!.exitCode, isNull);
    },
  );

  test(
    'retired handles do not consume admission and remain close-idempotent',
    () async {
      final handles = <String>[];
      for (var i = 0; i < maximumGitTerminals * 3; i++) {
        final events = _Events(open());
        final handle = await events.handle;
        handles.add(handle);
        await supervisor.closeTerminal(environmentId, handle);
        await events.done;
      }
      expect(handles.toSet().length, handles.length);
      for (final handle in handles) {
        await supervisor.closeTerminal(environmentId, handle);
      }
    },
  );

  test('cancellation is abandonment and closes while paused', () async {
    final events = _Events(open());
    final handle = await events.handle;
    final native = driver.sessions.single;
    events.subscription.pause();
    await events.subscription.cancel();
    expect(native.closes, 1);
    await supervisor.closeTerminal(environmentId, handle);
    await expectLater(
      supervisor.write(environmentId, handle, 'x'),
      throwsA(_code('terminal_gone')),
    );
    expect(events.events.where((event) => event.completed != null), isEmpty);
  });

  test('cancellation during preparation never starts a PTY', () async {
    driver.prepareGate = Completer<void>();
    final events = _Events(open());
    await driver.preparing.future;
    final cancelled = events.subscription.cancel();
    driver.prepareGate!.complete();
    await cancelled;
    expect(driver.starts, 0);
    expect(events.events, isEmpty);
  });

  test('tracks native starts and closes late PTY on abandonment', () async {
    driver.startGate = Completer<void>();
    final events = _Events(open());
    await driver.starting.future;
    final cancelled = events.subscription.cancel();
    driver.startGate!.complete();
    await cancelled;
    expect(driver.sessions.single.closes, 1);
    expect(events.events, isEmpty);
  });

  test(
    'shutdown fences lazy streams and in-flight starts synchronously',
    () async {
      final unlistened = open();
      driver.startGate = Completer<void>();
      final starting = _Events(open());
      await driver.starting.future;
      final closed = supervisor.close();
      final refused = _Events(unlistened);
      await refused.done;
      expect(refused.errors, [
        isA<EnvironmentFailure>().having(
          (e) => e.code,
          'code',
          'terminal_provider_closed',
        ),
      ]);
      driver.startGate!.complete();
      await closed;
      await starting.done;
      expect(driver.starts, 1);
      expect(driver.sessions.single.closes, 1);
      expect(starting.events, isEmpty);
      expect(starting.errors.single, _code('terminal_provider_closed'));
    },
  );

  test(
    'pause gates reads and ordered output, close bypasses output credit',
    () async {
      final events = _Events(open());
      final handle = await events.handle;
      final native = driver.sessions.single;
      events.subscription.pause();
      final reads = native.reads;
      native.output(utf8.encode('first\u001b[31m'));
      await Future<void>.delayed(Duration.zero);
      expect(native.reads, reads);
      expect(events.text, isEmpty);
      events.subscription.resume();
      await events.nextOutput();
      expect(events.text, 'first\u001b[31m');
      events.subscription.pause();
      await supervisor
          .closeTerminal(environmentId, handle)
          .timeout(const Duration(seconds: 1));
      expect(native.closes, 1);
      events.subscription.resume();
      await events.done;
      expect(events.errors, isEmpty);
      expect(
        events.events.last.completed!.termination,
        EnvironmentTerminalTermination.closed,
      );
    },
  );

  test(
    'pause inside output callback does not enqueue the rest of a chunk',
    () async {
      final events = _Events(open());
      await events.handle;
      events.onOutput = () => events.subscription.pause();
      driver.sessions.single.output(
        List<int>.filled(maximumGitTerminalChunkBytes, 97),
      );
      await events.nextOutput();
      await Future<void>.delayed(Duration.zero);
      expect(events.text.length, environmentTerminalTextLimit);
      events.onOutput = null;
      events.subscription.resume();
      await events.nextOutput(after: 1);
      expect(events.text.length, maximumGitTerminalChunkBytes);
      driver.sessions.single.exit(0);
      await events.done;
      expect(events.errors, isEmpty);
    },
  );

  test(
    'UTF8 carries between chunks, malformed replacement and surrogate-safe messages',
    () async {
      final events = _Events(open());
      await events.handle;
      final native = driver.sessions.single;
      final text = '${'a' * 8191}\u{1f642}\u001b[0m\r\n\u0000';
      final bytes = utf8.encode(text);
      native.output(bytes.sublist(0, 8193));
      native.output(bytes.sublist(8193));
      native.output([0xff, 0xe2]);
      native.exit(7);
      await events.done;
      expect(events.errors, isEmpty);
      expect(events.text, '$text\ufffd\ufffd');
      for (final event in events.events.where(
        (event) => event.output != null,
      )) {
        expect(
          event.output!.length,
          lessThanOrEqualTo(environmentTerminalTextLimit),
        );
        validateEnvironmentTerminalText(event.output!);
      }
    },
  );

  for (final size in [0, maximumGitTerminalChunkBytes + 1]) {
    test(
      'invalid native chunk size $size fails without dropping bytes or spinning',
      () async {
        final events = _Events(open());
        await events.handle;
        driver.sessions.single.output(List<int>.filled(size, 97));
        await events.done;
        expect(events.errors.single, _code('terminal_output_failed'));
        expect(events.text, isEmpty);
        expect(driver.sessions.single.closes, 1);
        expect(
          events.events.where((event) => event.completed != null),
          isEmpty,
        );
      },
    );
  }

  test(
    'input preserves controls, bounds bytes and resize accepts contract extremes',
    () async {
      final events = _Events(open());
      final handle = await events.handle;
      final text =
          '\u001b\r\n\u0000${'\u4e2d' * (environmentTerminalTextLimit - 4)}';
      await supervisor.write(environmentId, handle, text);
      final native = driver.sessions.single;
      expect(
        utf8.decode(native.writes.expand((bytes) => bytes).toList()),
        text,
      );
      expect(native.writes.length, 2);
      expect(
        native.writes.every(
          (bytes) => bytes.length <= maximumGitTerminalChunkBytes,
        ),
        isTrue,
      );
      for (final invalid in ['', 'x' * 8193, '\ud800']) {
        await expectLater(
          supervisor.write(environmentId, handle, invalid),
          throwsFormatException,
        );
      }
      await supervisor.resize(
        environmentId,
        handle,
        EnvironmentTerminalDimensions(columns: 1000, rows: 2000),
      );
      expect(native.dimensions!.columns, 1000);
      expect(native.dimensions!.rows, 2000);
      await supervisor.closeTerminal(environmentId, handle);
      await events.done;
      expect(events.errors, isEmpty);
    },
  );

  test(
    'bounded control admission, finite deadline and close independent of write',
    () async {
      final owner = GitTerminalSupervisor(
        driver: driver,
        operationDeadline: const Duration(milliseconds: 100),
      );
      addTearDown(owner.close);
      final events = _Events(open(owner: owner));
      final handle = await events.handle;
      final native = driver.sessions.single;
      native.writeGate = Completer<void>();
      final writing = owner.write(environmentId, handle, 'x');
      final failedWrite = expectLater(
        writing,
        throwsA(_code('terminal_control_failed')),
      );
      await native.writing.future;
      await expectLater(
        owner.resize(environmentId, handle, _dimensions()),
        throwsA(_code('terminal_busy')),
      );
      await failedWrite;
      await events.done;
      expect(native.closes, 1);
      expect(events.errors.single, _code('terminal_control_failed'));
      native.writeGate!.complete();
    },
  );

  test(
    'close interrupts blocked native write without waiting for its deadline',
    () async {
      final events = _Events(open());
      final handle = await events.handle;
      final native = driver.sessions.single;
      native.writeGate = Completer<void>();
      final writing = supervisor.write(environmentId, handle, 'x');
      final failedWrite = expectLater(writing, throwsA(_code('terminal_gone')));
      await native.writing.future;
      await supervisor
          .closeTerminal(environmentId, handle)
          .timeout(const Duration(seconds: 1));
      native.writeGate!.complete();
      await failedWrite;
      await events.done;
      expect(events.errors, isEmpty);
    },
  );

  test(
    'failed cleanup retains bounded admission rather than leaking new children',
    () async {
      final owner = GitTerminalSupervisor(driver: driver);
      for (var i = 0; i < maximumGitTerminalsPerEnvironment; i++) {
        final events = _Events(open(owner: owner));
        final handle = await events.handle;
        driver.sessions.last.closeError = StateError('cleanup failed');
        await expectLater(
          owner.closeTerminal(environmentId, handle),
          throwsA(_code('terminal_cleanup_failed')),
        );
        await events.done;
        expect(events.errors, hasLength(1));
        await expectLater(
          owner.closeTerminal(environmentId, handle),
          throwsA(_code('terminal_cleanup_failed')),
        );
        await expectLater(
          owner.write(environmentId, handle, 'x'),
          throwsA(_code('terminal_gone')),
        );
      }
      final rejected = _Events(open(owner: owner));
      await rejected.done;
      expect(rejected.errors.single, _code('terminal_limit'));
      expect(driver.starts, maximumGitTerminalsPerEnvironment);
      await expectLater(
        owner.close(),
        throwsA(_code('terminal_cleanup_failed')),
      );
    },
  );

  test('shutdown deadline retains ownership of a late native start', () async {
    driver.startGate = Completer<void>();
    final owner = GitTerminalSupervisor(
      driver: driver,
      operationDeadline: const Duration(milliseconds: 100),
    );
    final events = _Events(open(owner: owner));
    await driver.starting.future;
    await expectLater(owner.close(), throwsA(isA<TimeoutException>()));
    driver.startGate!.complete();
    await events.done;
    expect(driver.sessions.single.closes, 1);
    expect(events.events, isEmpty);
    expect(events.errors.single, _code('terminal_provider_closed'));
  });

  test(
    'generated ordinary queue cannot be held indefinitely by a native write',
    () async {
      final provider = GitWorktreeEnvironmentProvider(terminalDriver: driver);
      provider.liveObjects.bind(environmentId, environment);
      final dispatcher = EnvironmentProviderServiceDispatcher(
        EnvironmentProviderServiceAdapter(provider),
      );
      addTearDown(() async {
        await provider.close();
        await dispatcher.close();
      });
      final events = _Events(provider.openTerminal(environmentId, _request()));
      final handle = await events.handle;
      final native = driver.sessions.single;
      native.writeGate = Completer<void>();
      final writing = dispatcher.dispatch({
        'kind': 'request',
        'requestId': 1,
        'method': environmentProviderServiceWriteTerminalId,
        'payload': {
          'environmentId': environmentId.value,
          'handle': handle,
          'text': 'x',
        },
      });
      await native.writing.future;
      final closing = dispatcher.dispatch({
        'kind': 'request',
        'requestId': 2,
        'method': environmentProviderServiceCloseTerminalId,
        'payload': {'environmentId': environmentId.value, 'handle': handle},
      });
      final responses = await Future.wait([
        writing,
        closing,
      ]).timeout(const Duration(seconds: 10));
      expect(
        (responses.first['error']! as Map)['code'],
        'terminal_control_failed',
      );
      expect(responses.last.containsKey('error'), isFalse);
      expect(native.closes, 1);
      native.writeGate!.complete();
      await events.done;
    },
  );

  test('failed read releases resources and does not report an exit', () async {
    final events = _Events(open());
    await events.handle;
    driver.sessions.single.readError = StateError('read failed');
    driver.sessions.single.output([65]);
    await events.done;
    expect(events.errors.single, _code('terminal_failed'));
    expect(events.events.where((event) => event.completed != null), isEmpty);
    expect(driver.sessions.single.closes, 1);
  });

  test(
    'per Environment and generation limits count preparation, not just opened',
    () async {
      driver.prepareGate = Completer<void>();
      final accepted = <_Events>[];
      for (var i = 0; i < maximumGitTerminals; i++) {
        accepted.add(
          _Events(
            open(
              id: EnvironmentId(
                'env-${i ~/ maximumGitTerminalsPerEnvironment}',
              ),
            ),
          ),
        );
      }
      final rejected = _Events(open(id: EnvironmentId('additional')));
      await rejected.done;
      expect(rejected.errors.single, _code('terminal_limit'));
      driver.prepareGate!.complete();
      await Future.wait(accepted.map((events) => events.handle));
      expect(driver.starts, maximumGitTerminals);
      await supervisor.close();
      await Future.wait(accepted.map((events) => events.done));
    },
  );

  test('per Environment limit does not block another Environment', () async {
    driver.prepareGate = Completer<void>();
    final accepted = [
      for (var i = 0; i < maximumGitTerminalsPerEnvironment; i++)
        _Events(open()),
    ];
    final rejected = _Events(open());
    await rejected.done;
    expect(rejected.errors.single, _code('terminal_limit'));
    final other = _Events(open(id: EnvironmentId('other')));
    driver.prepareGate!.complete();
    await Future.wait([...accepted, other].map((events) => events.handle));
    await supervisor.close();
    await Future.wait([...accepted, other].map((events) => events.done));
  });

  test(
    'revalidates confined cwd after asynchronous native preparation',
    () async {
      await Directory('${root.path}/a').create();
      await Directory('${root.path}/b').create();
      final alias = await Link('${root.path}/alias').create('${root.path}/a');
      driver.prepareGate = Completer<void>();
      final events = _Events(open(cwd: 'alias'));
      await driver.preparing.future;
      await alias.update('${root.path}/b');
      driver.prepareGate!.complete();
      await events.done;
      expect(events.errors.single, _code('terminal_working_directory_changed'));
      expect(driver.starts, 0);
    },
  );

  test(
    'revalidation rejects cwd escaping selected source scope during setup',
    () async {
      await Directory('${root.path}/inside').create();
      final alias = await Link(
        '${root.path}/alias',
      ).create('${root.path}/inside');
      driver.prepareGate = Completer<void>();
      final events = _Events(open(cwd: 'alias'));
      await driver.preparing.future;
      await alias.update(root.parent.path);
      driver.prepareGate!.complete();
      await events.done;
      expect(events.errors.single, _code('outside_root'));
      expect(driver.starts, 0);
    },
  );

  test(
    'rejects initial traversal and outside symlink before native setup',
    () async {
      await Link('${root.path}/outside').create(root.parent.path);
      for (final entry in {
        '../': 'invalid_path',
        'outside': 'outside_root',
      }.entries) {
        final events = _Events(open(cwd: entry.key));
        await events.done;
        expect(events.errors.single, _code(entry.value));
      }
      expect(driver.prepares, 0);
      expect(driver.starts, 0);
    },
  );

  test(
    'child env uses foreground allowlist, canonical PWD and terminal TERM',
    () async {
      final events = _Events(open(program: 'sh'));
      final handle = await events.handle;
      final child = driver.childEnvironment!;
      expect(child['PWD'], environment.root.path);
      expect(child['TERM'], 'xterm-256color');
      expect(driver.executable, startsWith('/'));
      expect(
        child.keys.where(
          (key) => key.startsWith('ADELE_') || key.startsWith('GIT_'),
        ),
        isEmpty,
      );
      expect(child, isNot(contains('OPENAI_API_KEY')));
      expect(child, isNot(contains('SSH_AUTH_SOCK')));
      expect(
        child.keys.every(
          (key) =>
              const {
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
                'PWD',
                'TERM',
              }.contains(key) ||
              key.startsWith('LC_'),
        ),
        isTrue,
      );
      await supervisor.closeTerminal(environmentId, handle);
      await events.done;
    },
  );

  test(
    'explicit launch ignores SHELL and preserves verbatim argv and cwd',
    () async {
      final nested = await Directory('${root.path}/nested').create();
      final owner = GitTerminalSupervisor(
        driver: driver,
        parentEnvironment: {'SHELL': '/missing/shell', 'PATH': '/usr/bin:/bin'},
      );
      addTearDown(owner.close);
      final arguments = ['', 'literal | argument', r'$HOME', 'two words'];
      final events = _Events(
        owner.open(
          environmentId: environmentId,
          resolveEnvironment: () => environment,
          request: EnvironmentTerminalRequest(
            launchKind: EnvironmentTerminalLaunchKind.explicitProgram,
            program: '/bin/sh',
            arguments: arguments,
            relativeWorkingDirectory: 'nested',
            dimensions: _dimensions(),
          ),
        ),
      );
      final handle = await events.handle;
      expect(driver.executable, '/bin/sh');
      expect(driver.arguments, arguments);
      expect(driver.workingDirectory, nested.path);
      await owner.closeTerminal(environmentId, handle);
      await events.done;
      expect(events.errors, isEmpty);
    },
  );

  for (final preference in <String?>[
    null,
    '/bin/sh',
    'chosen-shell',
    './bin/chosen-shell',
    'shell with spaces',
  ]) {
    test('default shell resolves one executable: $preference', () async {
      final bin = await Directory('${root.path}/bin').create();
      final home = await Directory('${root.path}/home').create();
      for (final name in ['chosen-shell', 'shell with spaces']) {
        await Link('${bin.path}/$name').create('/bin/sh');
      }
      final parent = <String, String>{
        ..._environmentSentinels,
        'PATH': bin.path,
        'HOME': home.path,
        'SHELL': ?preference,
        'PWD': '/wrong/cwd',
        'TERM': 'wrong-term',
        'ENV': '/personal/startup',
        'BASH_ENV': '/personal/startup',
      };
      final owner = GitTerminalSupervisor(
        driver: driver,
        parentEnvironment: parent,
      );
      addTearDown(owner.close);
      parent['SHELL'] = '/mutated/shell';
      final events = _Events(
        owner.open(
          environmentId: environmentId,
          resolveEnvironment: () => environment,
          request: _defaultShellRequest(),
        ),
      );
      final handle = await events.handle;
      expect(driver.executable, switch (preference) {
        null || '/bin/sh' => '/bin/sh',
        './bin/chosen-shell' => '${root.path}/./bin/chosen-shell',
        _ => '${bin.path}/$preference',
      });
      expect(driver.arguments, ['-i']);
      expect(driver.workingDirectory, environment.root.path);
      expect(driver.dimensions!.columns, 80);
      expect(driver.dimensions!.rows, 24);
      expect(driver.childEnvironment, {
        'PATH': bin.path,
        'HOME': home.path,
        'SHELL': ?preference,
        'PWD': environment.root.path,
        'TERM': 'xterm-256color',
      });
      await owner.closeTerminal(environmentId, handle);
      await events.done;
      expect(events.errors, isEmpty);
    });
  }

  test(
    'explicit invalid SHELL never falls back or starts a terminal',
    () async {
      final nonExecutable = await File(
        '${root.path}/not-executable',
      ).writeAsString('no');
      final broken = await Link(
        '${root.path}/broken-shell',
      ).create('/missing/shell');
      await Link('${root.path}/\ufffd').create('/bin/sh');
      for (final preference in [
        '',
        ' ',
        '/missing/shell',
        'missing-shell',
        '/bin/sh -i',
        'sh -i',
        '"/bin/sh"',
        r'$SHELL',
        '/bin/sh\u0000ignored',
        '\ud800',
        '${root.path}/\ud800',
        '${root.path}/\udc00',
        root.path,
        nonExecutable.path,
        broken.path,
      ]) {
        final owner = GitTerminalSupervisor(
          driver: driver,
          parentEnvironment: {'SHELL': preference, 'PATH': '/usr/bin:/bin'},
        );
        final events = _Events(
          owner.open(
            environmentId: environmentId,
            resolveEnvironment: () => environment,
            request: _defaultShellRequest(),
          ),
        );
        await events.done;
        expect(events.events, isEmpty, reason: preference);
        expect(
          events.errors.single,
          _code('terminal_executable_not_found'),
          reason: preference,
        );
        await owner.close();
      }
      expect(driver.starts, 0);
    },
  );

  test(
    'default shell revalidates the Environment root after preparation',
    () async {
      final scope = await Directory('${root.path}/scope').create();
      environment = WorktreeEnvironment(scope);
      final owner = GitTerminalSupervisor(
        driver: driver,
        parentEnvironment: const {},
      );
      addTearDown(owner.close);
      driver.prepareGate = Completer<void>();
      final events = _Events(
        owner.open(
          environmentId: environmentId,
          resolveEnvironment: () => environment,
          request: _defaultShellRequest(),
        ),
      );
      await driver.preparing.future;
      await scope.rename('${root.path}/moved');
      await Link(scope.path).create(root.path);
      driver.prepareGate!.complete();
      await events.done;
      expect(events.events, isEmpty);
      expect(events.errors.single, _code('outside_root'));
      expect(driver.starts, 0);
    },
  );

  test('startup and transport errors are not successful completion', () async {
    driver.startError = StateError('native setup failed');
    final failedStart = _Events(open());
    await failedStart.done;
    expect(failedStart.events, isEmpty);
    expect(failedStart.errors.single, _code('terminal_failed'));
    driver.startError = null;
    final events = _Events(open());
    await events.handle;
    driver.sessions.single.fail(StateError('helper transport lost'));
    await events.done;
    expect(events.errors.single, _code('terminal_failed'));
    expect(events.events.where((event) => event.completed != null), isEmpty);
    expect(driver.sessions.single.closes, 1);
  });

  for (final helper in <String?>[
    null,
    '/missing/adele-pty-helper',
    'relative-helper',
  ]) {
    test(
      'unavailable helper $helper leaves filesystem initialization usable',
      () async {
        final provider = GitWorktreeEnvironmentProvider(ptyHelperPath: helper);
        addTearDown(provider.close);
        provider.liveObjects.bind(environmentId, environment);
        await provider.createTextFile(environmentId, 'still-usable.txt', 'yes');
        final events = _Events(
          provider.openTerminal(environmentId, _request()),
        );
        await events.done;
        expect(events.errors.single, _code(environmentTerminalUnavailableCode));
        expect(
          (await provider.readFile(environmentId, 'still-usable.txt')).text,
          'yes',
        );
      },
    );
  }

  group(
    'prepared production driver',
    () {
      late Directory artifacts;
      late File helper;
      setUpAll(() async {
        artifacts = await Directory.systemTemp.createTemp(
          'adele-terminal-driver-',
        );
        helper = File('${artifacts.path}/git-pty-helper');
        await prepareGitPtyHelper(
          repositoryRoot: Directory.current.parent.parent.parent.parent,
          output: helper,
        );
      });
      tearDownAll(() async => artifacts.delete(recursive: true));

      GitWorktreeEnvironmentProvider provider({String? shellPreference}) {
        final home = Directory('${root.path}/home')..createSync();
        final provider = GitWorktreeEnvironmentProvider(
          ptyHelperPath: helper.path,
          terminalEnvironment: {
            ..._environmentSentinels,
            'PATH': '/usr/bin:/bin',
            'HOME': home.path,
            'SHELL': ?shellPreference,
          },
        );
        provider.liveObjects.bind(environmentId, environment);
        addTearDown(provider.close);
        return provider;
      }

      Stream<EnvironmentTerminalEvent> shell(
        GitWorktreeEnvironmentProvider provider,
        String script,
      ) => provider.openTerminal(
        environmentId,
        EnvironmentTerminalRequest(
          launchKind: EnvironmentTerminalLaunchKind.explicitProgram,
          program: '/bin/sh',
          arguments: ['-c', script],
          relativeWorkingDirectory: '',
          dimensions: _dimensions(),
        ),
      );

      for (final preference in <String?>[null, '/bin/bash']) {
        test(
          'real default shell is interactive at root: $preference',
          () async {
            final live = provider(shellPreference: preference);
            final home = '${root.path}/home';
            // Use a fixture HOME rather than personal shell startup files.
            await File(
              '$home/.bashrc',
            ).writeAsString("printf 'FIXTURE-RC\\n'\n");
            final events = _Events(
              live.openTerminal(environmentId, _defaultShellRequest()),
            );
            final handle = await events.handle.timeout(
              const Duration(seconds: 10),
            );
            await live.writeTerminal(environmentId, handle, r'''
stty -echo
case $- in *i*) printf 'INTERACTIVE=yes\n';; *) printf 'INTERACTIVE=no\n';; esac
printf 'ARGV0=%s\nCWD=%s\nHOME=%s\nTERM=%s\nSECRET=%s\n' "$0" "$PWD" "$HOME" "$TERM" "${ADELE_TERMINAL_TEST_SECRET-unset}"
stty size
printf 'PROBE-DONE\n'
''');
            await events.untilText('PROBE-DONE\r\n');
            expect(events.text, contains('INTERACTIVE=yes\r\n'));
            expect(
              events.text,
              contains('ARGV0=${preference ?? '/bin/sh'}\r\n'),
            );
            expect(events.text, contains('CWD=${environment.root.path}\r\n'));
            expect(events.text, contains('HOME=$home\r\n'));
            expect(events.text, contains('TERM=xterm-256color\r\n'));
            expect(events.text, contains('SECRET=unset\r\n'));
            expect(events.text, contains('24 80\r\n'));
            if (preference != null) {
              expect(events.text, contains('FIXTURE-RC\r\n'));
            }
            await live.writeTerminal(environmentId, handle, 'exit 17\n');
            await events.done.timeout(const Duration(seconds: 10));
            expect(events.errors, isEmpty);
            expect(
              events.events.last.completed!.termination,
              EnvironmentTerminalTermination.exited,
            );
            expect(events.events.last.completed!.exitCode, 17);
          },
        );
      }

      test(
        'real controlling PTY, scoped cwd, terminal env, UTF8 and exit status',
        () async {
          final live = provider();
          final events = _Events(
            shell(live, r'''
test -t 0 && test -t 1 && test -t 2 && printf 'TTY=yes\n'
printf 'CWD=%s\nTERM=%s\n' "$PWD" "$TERM"
printf '\033[31m\342'
printf '\230\203\033[0m\377\n'
exit 37
'''),
          );
          await events.done.timeout(const Duration(seconds: 10));
          expect(events.errors, isEmpty);
          expect(events.events.first.opened, isNotNull);
          expect(events.text, contains('TTY=yes\r\n'));
          expect(events.text, contains('CWD=${environment.root.path}\r\n'));
          expect(events.text, contains('TERM=xterm-256color\r\n'));
          expect(events.text, contains('\u001b[31m\u2603\u001b[0m\ufffd\r\n'));
          expect(
            events.events.last.completed!.termination,
            EnvironmentTerminalTermination.exited,
          );
          expect(events.events.last.completed!.exitCode, 37);
        },
      );

      test('explicit executable symlink preserves argv zero', () async {
        final live = provider();
        final executable = Link('${environment.root.path}/terminal-shell');
        await executable.create('/bin/sh');
        final events = _Events(
          live.openTerminal(
            environmentId,
            EnvironmentTerminalRequest(
              launchKind: EnvironmentTerminalLaunchKind.explicitProgram,
              program: './terminal-shell',
              arguments: ['-c', r'printf "ARGV0=%s\n" "$0"'],
              relativeWorkingDirectory: '',
              dimensions: _dimensions(),
            ),
          ),
        );
        await events.done.timeout(const Duration(seconds: 10));
        expect(events.errors, isEmpty);
        expect(
          events.text,
          contains('ARGV0=${environment.root.path}/./terminal-shell\r\n'),
        );
        expect(events.events.last.completed!.exitCode, 0);
      });

      test(
        'acknowledged input and geometry, provider close while output is paused',
        () async {
          final live = provider();
          final events = _Events(
            shell(live, r'''
stty -echo
printf 'READY\n'
while IFS= read -r line; do
  if [ "$line" = size ]; then stty size; fi
done
'''),
          );
          final handle = await events.handle;
          await events.untilText('READY');
          await live.resizeTerminal(
            environmentId,
            handle,
            EnvironmentTerminalDimensions(columns: 1000, rows: 2000),
          );
          await live.writeTerminal(environmentId, handle, 'size\n');
          await events.untilText('2000 1000');
          events.subscription.pause();
          await live.close().timeout(const Duration(seconds: 7));
          events.subscription.resume();
          await events.done;
          expect(events.errors, isEmpty);
          expect(
            events.events.last.completed!.termination,
            EnvironmentTerminalTermination.closed,
          );
          await live.closeTerminal(environmentId, handle);
        },
      );

      test(
        'one Unicode input operation spans ordered acknowledged native chunks',
        () async {
          final live = provider();
          final events = _Events(
            shell(live, r'''
stty raw -echo
printf 'READY\n'
dd bs=1 count=24576 2>/dev/null | wc -c
printf 'BYTES-DONE\n'
read -r stop
'''),
          );
          final handle = await events.handle;
          await events.untilText('READY');
          await live.writeTerminal(
            environmentId,
            handle,
            '\u4e2d' * environmentTerminalTextLimit,
          );
          await events.untilText('BYTES-DONE');
          expect(events.text, contains('24576'));
          await live.closeTerminal(environmentId, handle);
          await events.done;
          expect(events.errors, isEmpty);
          expect(
            events.events.last.completed!.termination,
            EnvironmentTerminalTermination.closed,
          );
        },
      );

      for (final sameEnvironment in [true, false]) {
        test(
          'simultaneous PTYs are isolated in ${sameEnvironment ? 'the same' : 'different'} Environments',
          () async {
            final live = provider();
            final secondId = sameEnvironment
                ? environmentId
                : EnvironmentId('second');
            final secondRoot = sameEnvironment
                ? environment.root
                : await Directory('${root.path}/second').create();
            if (!sameEnvironment) {
              live.liveObjects.bind(secondId, WorktreeEnvironment(secondRoot));
            }
            EnvironmentTerminalRequest tagged(String tag) =>
                EnvironmentTerminalRequest(
                  launchKind: EnvironmentTerminalLaunchKind.explicitProgram,
                  program: '/bin/sh',
                  arguments: [
                    '-c',
                    r'''
stty -echo
printf 'READY:%s:%s\n' "$1" "$PWD"
while IFS= read -r line; do
  if [ "$line" = size ]; then stty size
  else printf 'RESULT:%s:%s\n' "$1" "$line"; fi
done
''',
                    'terminal-test',
                    tag,
                  ],
                  relativeWorkingDirectory: '',
                  dimensions: _dimensions(),
                );
            final first = _Events(
              live.openTerminal(environmentId, tagged('FIRST')),
            );
            final second = _Events(
              live.openTerminal(secondId, tagged('SECOND')),
            );
            final handles = await Future.wait([first.handle, second.handle]);
            expect(handles[0], isNot(handles[1]));
            await Future.wait([
              first.untilText('READY:FIRST:${environment.root.path}'),
              second.untilText('READY:SECOND:${secondRoot.path}'),
            ]);
            if (!sameEnvironment) {
              await expectLater(
                live.writeTerminal(environmentId, handles[1], 'forged\n'),
                throwsA(_code('invalid_terminal_handle')),
              );
              await expectLater(
                live.closeTerminal(secondId, handles[0]),
                throwsA(_code('invalid_terminal_handle')),
              );
            }
            await Future.wait([
              live.writeTerminal(environmentId, handles[0], 'alpha\n'),
              live.writeTerminal(secondId, handles[1], 'beta\n'),
            ]);
            await Future.wait([
              first.untilText('RESULT:FIRST:alpha'),
              second.untilText('RESULT:SECOND:beta'),
            ]);
            await live.resizeTerminal(
              environmentId,
              handles[0],
              EnvironmentTerminalDimensions(columns: 99, rows: 33),
            );
            await Future.wait([
              live.writeTerminal(environmentId, handles[0], 'size\n'),
              live.writeTerminal(secondId, handles[1], 'size\n'),
            ]);
            await Future.wait([
              first.untilText('33 99'),
              second.untilText('24 80'),
            ]);
            await live.closeTerminal(environmentId, handles[0]);
            await first.done;
            await live.writeTerminal(secondId, handles[1], 'after-close\n');
            await second.untilText('RESULT:SECOND:after-close');
            expect(first.text, isNot(contains('SECOND')));
            expect(second.text, isNot(contains('FIRST')));
            expect(
              first.events.last.completed!.termination,
              EnvironmentTerminalTermination.closed,
            );
            expect(
              second.events.where((event) => event.completed != null),
              isEmpty,
            );
            await live.closeTerminal(secondId, handles[1]);
            await second.done;
            expect(first.errors, isEmpty);
            expect(second.errors, isEmpty);
          },
        );
      }

      test(
        'real child strips inherited credential and routing sentinels',
        () async {
          // A separate Dart process supplies an actual inherited environment without
          // mutating the shared test host's process-global environment through FFI.
          final result = await Process.run(
            Platform.resolvedExecutable,
            [
              File('test/terminal_resources_test.dart').absolute.path,
              '--terminal-env-probe',
              helper.path,
              root.path,
            ],
            environment: {
              ..._environmentSentinels,
              'PATH': '/usr/bin:/bin',
              'LANG': 'C',
              'LC_CTYPE': 'C',
              'TERM': 'parent-terminal',
            },
          );
          expect(result.exitCode, 0, reason: result.stderr.toString());
          final report = jsonDecode(result.stdout.toString()) as Map;
          expect(report['parent'], _environmentSentinels);
          final child = report['child'] as Map;
          for (final entry in _environmentSentinels.entries) {
            expect(child.containsKey(entry.key), isFalse, reason: entry.key);
            expect(child.values, isNot(contains(entry.value)));
          }
          expect(child['PATH'], '/usr/bin:/bin');
          expect(child['LANG'], 'C');
          expect(child['LC_CTYPE'], 'C');
          expect(child['PWD'], environment.root.path);
          expect(child['TERM'], 'xterm-256color');
        },
      );

      test(
        'incremental UTF8 and ANSI survive input-gated native writes',
        () async {
          final live = provider();
          final events = _Events(
            shell(live, r'''
stty -echo
printf 'PART1:\033['
read -r step
printf '31mX\342'
read -r step
printf '\230\203Y\033[0m\377\n'
read -r stop
'''),
          );
          final handle = await events.handle;
          await events.untilText('PART1:\u001b[');
          expect(events.text, 'PART1:\u001b[');
          await live.writeTerminal(environmentId, handle, 'next\n');
          await events.untilText('\u001b[31mX');
          expect(events.text, 'PART1:\u001b[31mX');
          await live.writeTerminal(environmentId, handle, 'next\n');
          await events.untilText('\u2603Y\u001b[0m\ufffd\r\n');
          expect(events.text, 'PART1:\u001b[31mX\u2603Y\u001b[0m\ufffd\r\n');
          for (final event in events.events.where(
            (event) => event.output != null,
          )) {
            validateEnvironmentTerminalText(event.output!);
          }
          await live.closeTerminal(environmentId, handle);
          await events.done;
          expect(events.errors, isEmpty);
        },
      );

      test(
        'Ctrl+C interrupts a Bash foreground job without closing its shell',
        () async {
          final live = provider();
          final events = _Events(
            live.openTerminal(
              environmentId,
              EnvironmentTerminalRequest(
                launchKind: EnvironmentTerminalLaunchKind.explicitProgram,
                program: '/bin/bash',
                arguments: const ['--noprofile', '--norc', '-i'],
                relativeWorkingDirectory: '',
                dimensions: _dimensions(),
              ),
            ),
          );
          final handle = await events.handle;
          await live.writeTerminal(
            environmentId,
            handle,
            'stty -echo; PS1="ADELE-READY> "; printf "SHELL=%s\\n" "\$\$"\n',
          );
          await events.untilText(RegExp(r'SHELL=\d+\r?\n'));
          final shellPid = RegExp(r'SHELL=(\d+)').firstMatch(events.text)![1]!;
          await live.writeTerminal(
            environmentId,
            handle,
            "/bin/sh -c 'printf \"JOB=%s\\n\" \"\$\$\"; exec /bin/sleep 60'\n",
          );
          await events.untilText(RegExp(r'JOB=\d+\r?\n'));
          final jobPid = RegExp(r'JOB=(\d+)').firstMatch(events.text)![1]!;
          expect(jobPid, isNot(shellPid));
          expect(await Directory('/proc/$jobPid').exists(), isTrue);
          final interruptedAt = events.text.length;
          await live.writeTerminal(environmentId, handle, '\u0003');
          await events.untilText('ADELE-READY> ', after: interruptedAt);
          expect(await Directory('/proc/$jobPid').exists(), isFalse);
          await live.writeTerminal(
            environmentId,
            handle,
            'printf "STATUS=%s ALIVE=%s\\n" "\$?" "\$\$"\n',
          );
          await events.untilText('STATUS=130 ALIVE=$shellPid');
          expect(
            events.events.where((event) => event.completed != null),
            isEmpty,
          );
          expect(events.errors, isEmpty);
          await live.closeTerminal(environmentId, handle);
          await events.done;
          expect(
            events.events.last.completed!.termination,
            EnvironmentTerminalTermination.closed,
          );
          expect(events.errors, isEmpty);
        },
      );
    },
    skip: !Platform.isLinux || Abi.current() != Abi.linuxX64
        ? 'Requires Linux x64 and devpts.'
        : false,
  );

  test(
    'real Git nested source keeps terminal cwd inside linked selected scope',
    () async {
      final source = await Directory('${root.path}/repo').create();
      await Directory(
        '${source.path}/selected/project',
      ).create(recursive: true);
      await File(
        '${source.path}/selected/project/file.txt',
      ).writeAsString('source');
      await _git(source, ['init', '--quiet']);
      await _git(source, ['add', '.']);
      await _git(source, [
        '-c',
        'user.name=Terminal Test',
        '-c',
        'user.email=terminal@example.invalid',
        'commit',
        '--quiet',
        '-m',
        'fixture',
      ]);
      final selected = Directory('${source.path}/selected/project');
      final project = Project(
        id: ProjectId('project'),
        sourceLocation: selected.uri,
      );
      final task = Task(
        id: TaskId('task'),
        projectId: project.id,
        title: 'Terminal test',
      );
      final provider = GitWorktreeEnvironmentProvider(
        terminalDriver: driver,
        terminalEnvironment: const {'SHELL': '/bin/sh'},
      );
      addTearDown(provider.close);
      final retained = Environment(
        id: environmentId,
        taskId: task.id,
        role: EnvironmentRole.primary,
        providerId: provider.providerId,
        providerState: null,
      );
      await provider.establish(
        LocalEnvironment(project: project, task: task, value: retained),
      );
      final scoped = provider.liveObjects.resolve(environmentId).root;
      final events = _Events(
        provider.openTerminal(environmentId, _defaultShellRequest()),
      );
      final handle = await events.handle;
      expect(driver.workingDirectory, scoped.path);
      expect(scoped.path, endsWith('/selected/project'));
      expect(scoped.path, isNot(selected.path));
      expect(driver.childEnvironment!['PWD'], scoped.path);
      final refused = _Events(
        provider.openTerminal(EnvironmentId('unknown'), _request()),
      );
      await refused.done;
      expect(refused.errors.single, _code('environment_not_live'));
      final lazy = provider.openTerminal(environmentId, _request());
      final closing = provider.close();
      final fenced = _Events(lazy);
      await closing;
      await fenced.done;
      await events.done;
      expect(fenced.errors.single, _code('terminal_provider_closed'));
      expect(provider.liveObjects.length, 0);
      await provider.closeTerminal(environmentId, handle);
    },
  );
}

const _environmentSentinels = <String, String>{
  'ADELE_TERMINAL_TEST_SECRET': 'adele-test-sentinel',
  'OPENAI_API_KEY': 'openai-test-sentinel',
  'GIT_DIR': '/sentinel/git-dir',
  'GIT_WORK_TREE': '/sentinel/git-worktree',
  'SSH_AUTH_SOCK': '/sentinel/ssh-socket',
  'UNLISTED_TERMINAL_VALUE': 'unlisted-test-sentinel',
};

Future<void> _environmentProbe(String helper, String root) async {
  final provider = GitWorktreeEnvironmentProvider(ptyHelperPath: helper);
  final id = EnvironmentId('environment-probe');
  provider.liveObjects.bind(id, WorktreeEnvironment(Directory(root)));
  try {
    final events = await provider
        .openTerminal(
          id,
          EnvironmentTerminalRequest(
            launchKind: EnvironmentTerminalLaunchKind.explicitProgram,
            program: '/usr/bin/env',
            arguments: const [],
            relativeWorkingDirectory: '',
            dimensions: _dimensions(),
          ),
        )
        .toList();
    if (events.last.completed?.exitCode != 0) {
      throw StateError('Environment probe failed.');
    }
    final child = <String, String>{};
    for (final line
        in events.map((event) => event.output ?? '').join().split('\r\n')) {
      final separator = line.indexOf('=');
      if (separator > 0) {
        child[line.substring(0, separator)] = line.substring(separator + 1);
      }
    }
    stdout.write(
      jsonEncode({
        'parent': {
          for (final key in _environmentSentinels.keys)
            key: Platform.environment[key],
        },
        'child': child,
      }),
    );
  } finally {
    await provider.close();
  }
}

EnvironmentTerminalDimensions _dimensions() =>
    EnvironmentTerminalDimensions(columns: 80, rows: 24);
EnvironmentTerminalRequest _defaultShellRequest() => EnvironmentTerminalRequest(
  launchKind: EnvironmentTerminalLaunchKind.defaultShell,
  program: null,
  arguments: const [],
  relativeWorkingDirectory: '',
  dimensions: _dimensions(),
);
EnvironmentTerminalRequest _request({
  String cwd = '',
  String program = '/bin/sh',
}) => EnvironmentTerminalRequest(
  launchKind: EnvironmentTerminalLaunchKind.explicitProgram,
  program: program,
  arguments: const ['-i'],
  relativeWorkingDirectory: cwd,
  dimensions: _dimensions(),
);
Matcher _code(String code) =>
    isA<EnvironmentFailure>().having((failure) => failure.code, 'code', code);

final class _Events {
  _Events(Stream<EnvironmentTerminalEvent> stream) {
    subscription = stream.listen(
      (event) {
        events.add(event);
        if (event.opened != null) _handle.complete(event.opened!.handle);
        if (event.output != null) {
          onOutput?.call();
          _output?.complete();
          _output = null;
        }
      },
      onError: (Object error) => errors.add(error),
      onDone: _done.complete,
    );
  }
  final events = <EnvironmentTerminalEvent>[];
  final errors = <Object>[];
  final _handle = Completer<String>();
  final _done = Completer<void>();
  Completer<void>? _output;
  void Function()? onOutput;
  late final StreamSubscription<EnvironmentTerminalEvent> subscription;
  Future<String> get handle => _handle.future;
  Future<void> get done => _done.future;
  String get text => events.map((event) => event.output ?? '').join();
  Future<void> nextOutput({int after = 0}) {
    if (events.where((event) => event.output != null).length > after) {
      return Future<void>.value();
    }
    return (_output ??= Completer<void>()).future;
  }

  Future<void> untilText(Pattern expected, {int after = 0}) async {
    while (!text.substring(after).contains(expected)) {
      if (_done.isCompleted) {
        fail('Terminal ended before $expected: $errors; $text');
      }
      await nextOutput(
        after: events.where((event) => event.output != null).length,
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          fail('Timed out waiting for $expected: $errors; $text');
        },
      );
    }
  }
}

final class _Driver implements GitTerminalDriver {
  int prepares = 0;
  int starts = 0;
  final preparing = Completer<void>();
  final starting = Completer<void>();
  Completer<void>? prepareGate;
  Completer<void>? startGate;
  Object? startError;
  final sessions = <_Session>[];
  String? executable;
  List<String>? arguments;
  EnvironmentTerminalDimensions? dimensions;
  String? workingDirectory;
  Map<String, String>? childEnvironment;
  @override
  Future<void> prepare() async {
    prepares++;
    if (!preparing.isCompleted) preparing.complete();
    await prepareGate?.future;
  }

  @override
  Future<GitTerminalSession> start({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    required Map<String, String> environment,
    required EnvironmentTerminalDimensions dimensions,
  }) async {
    starts++;
    this.executable = executable;
    this.arguments = arguments;
    this.dimensions = dimensions;
    this.workingDirectory = workingDirectory;
    childEnvironment = environment;
    if (!starting.isCompleted) starting.complete();
    await startGate?.future;
    if (startError case final error?) throw error;
    final session = _Session();
    sessions.add(session);
    return session;
  }
}

final class _Session implements GitTerminalSession {
  final _output = Queue<Uint8List>();
  final _exit = Completer<int>();
  Completer<void>? _reader;
  bool _eof = false;
  int reads = 0;
  int closes = 0;
  Object? closeError;
  Object? readError;
  final writes = <Uint8List>[];
  final writing = Completer<void>();
  Completer<void>? writeGate;
  EnvironmentTerminalDimensions? dimensions;
  @override
  Future<int> get exitCode => _exit.future;
  void output(List<int> bytes) {
    _output.add(Uint8List.fromList(bytes));
    _wake();
  }

  void exit(int code) {
    _eof = true;
    _exit.complete(code);
    _wake();
  }

  void fail(Object error) {
    _exit.completeError(error);
    _eof = true;
    _wake();
  }

  @override
  Future<Uint8List?> read() async {
    reads++;
    while (_output.isEmpty && !_eof) {
      _reader = Completer<void>();
      await _reader!.future;
    }
    if (readError case final error?) throw error;
    return _output.isNotEmpty ? _output.removeFirst() : null;
  }

  @override
  Future<void> write(Uint8List bytes) async {
    writes.add(bytes);
    if (!writing.isCompleted) writing.complete();
    await writeGate?.future;
  }

  @override
  Future<void> resize(EnvironmentTerminalDimensions dimensions) async =>
      this.dimensions = dimensions;
  @override
  Future<void> close() async {
    closes++;
    _eof = true;
    if (!_exit.isCompleted) _exit.complete(0);
    _wake();
    if (closeError case final error?) throw error;
  }

  void _wake() {
    final reader = _reader;
    _reader = null;
    reader?.complete();
  }
}

Future<void> _git(Directory source, List<String> arguments) async {
  final result = await Process.run('git', ['-C', source.path, ...arguments]);
  expect(result.exitCode, 0, reason: result.stderr.toString());
}
