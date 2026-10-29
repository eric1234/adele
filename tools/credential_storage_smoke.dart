import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const _gate = 'ADELE_CREDENTIAL_STORAGE_SMOKE';
const _fixture = 'ADELE_CREDENTIAL_STORAGE_FIXTURE';
const _timeout = Duration(seconds: 30);

// SDK-only: help and refusal must work before bootstrap or native asset loading.
Future<void> main(List<String> args) async {
  if (args.length == 1 && ['--help', '-h'].contains(args.single)) {
    stdout.writeln(
      '''Linux credential storage smoke (disposable keyring only).
From the bootstrapped repository root, with the pinned Flutter SDK:
  ADELE_CREDENTIAL_STORAGE_SMOKE=1 FLUTTER_ROOT=<SDK> dart tools/credential_storage_smoke.dart

Requires Linux x64, pinned Rust, binutils, setsid, dbus-daemon,
dbus-run-session, gdbus and gnome-keyring-daemon. No pub resolution is run.
Creates a private bus without activation directories and a temporary keyring.
Credential values and the random master password are never printed or arguments.
The user's keyring is never used. Ordinary app tests skip this real-keyring test.''',
    );
    return;
  }
  if (Platform.environment[_gate] != '1') {
    stderr.writeln('Refusing credential smoke without $_gate=1. Use --help.');
    exitCode = 2;
    return;
  }
  if (!Platform.isLinux ||
      !(args.isEmpty || (args.length == 1 && args.single == '--inside'))) {
    stderr.writeln('Credential smoke requires Linux and no public arguments.');
    exitCode = 2;
    return;
  }
  final root = File.fromUri(Platform.script).parent.parent;
  final children = _Children(processGroups: args.isEmpty);
  var stage = 'prerequisites';
  Directory? temporary;
  try {
    if (args.isNotEmpty) {
      await _inside(root, children);
      return;
    }
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    _require(flutterRoot != null && Directory(flutterRoot).isAbsolute);
    final flutter = '$flutterRoot/bin/flutter';
    final dart = '$flutterRoot/bin/cache/dart-sdk/bin/dart';
    _require(File(flutter).existsSync() && File(dart).existsSync());
    for (final name in [
      'setsid',
      'dbus-daemon',
      'dbus-run-session',
      'gdbus',
      'gnome-keyring-daemon',
      'rustup',
      'nm',
      'readelf',
    ]) {
      stage = 'required tool $name';
      _require(_onPath(name));
    }
    stage = 'pinned Flutter identity';
    final pin =
        jsonDecode(File('${root.path}/toolchain.json').readAsStringSync())
            as Map<String, dynamic>;
    final version =
        jsonDecode(
              await children.command(flutter, [
                '--version',
                '--machine',
              ], capture: true),
            )
            as Map<String, dynamic>;
    for (final pair in {
      'flutter': 'frameworkVersion',
      'flutterRevision': 'frameworkRevision',
      'engineRevision': 'engineRevision',
      'dart': 'dartSdkVersion',
    }.entries) {
      _require(pin[pair.key] != null && pin[pair.key] == version[pair.value]);
    }
    _require(Platform.version.split(' ').first == pin['dart']);
    _require(
      File(Platform.resolvedExecutable).resolveSymbolicLinksSync() ==
          File(dart).resolveSymbolicLinksSync(),
    );
    final config = File('${root.path}/.dart_tool/package_config.json');
    stage = 'bootstrapped workspace';
    _require(config.existsSync());
    _require(
      ((jsonDecode(config.readAsStringSync()) as Map)['packages'] as List).any(
        (dynamic package) => package['name'] == 'adele_credential_store',
      ),
    );
    final native = '${root.path}/packages/credential_store/native';
    final rust = File('$native/rust-toolchain').readAsStringSync().trim();
    stage = 'pinned Rust identity';
    final rustVersion = await children.command('rustup', [
      'run',
      rust,
      'rustc',
      '--version',
    ], capture: true);
    _require(rustVersion.startsWith('rustc $rust '));
    _require(
      (await children.command('uname', ['-m'], capture: true)).trim() ==
          'x86_64',
    );
    stage = 'pinned native fixture build';
    await children.command(
      'rustup',
      [
        'run',
        rust,
        'cargo',
        'build',
        '--locked',
        '--release',
        '--features',
        'fixture-probe',
        '--bin',
        'credential_probe',
        '--target-dir',
        '$native/target',
      ],
      directory: native,
      environment: Map<String, String>.of(Platform.environment)
        ..remove('RUSTFLAGS')
        ..['CARGO_ENCODED_RUSTFLAGS'] =
            '-C\x1fprefer-dynamic=no\x1f-C\x1fpanic=unwind',
      timeout: const Duration(minutes: 5),
    );
    stdout.writeln('PASS pinned toolchain and production native fixture build');

    stage = 'private bus';
    temporary = Directory.systemTemp.createTempSync('adele-credential-smoke-');
    for (final name in ['home', 'data', 'config', 'cache', 'run', 'control']) {
      Directory('${temporary.path}/$name').createSync();
    }
    // No standard_session_servicedirs or included system configuration: this bus
    // cannot activate the user's Secret Service or any graphical unlock helper.
    final busConfig = File('${temporary.path}/bus.conf')
      ..writeAsStringSync('''
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=${temporary.path}/run/bus</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
    <allow own="*"/>
  </policy>
</busconfig>
''');
    final env = Map<String, String>.of(Platform.environment)
      ..remove('DBUS_SESSION_BUS_ADDRESS')
      ..remove('DBUS_SESSION_BUS_PID')
      ..remove('DBUS_STARTER_ADDRESS')
      ..remove('DBUS_STARTER_BUS_TYPE')
      ..remove('DISPLAY')
      ..remove('WAYLAND_DISPLAY')
      ..remove('XAUTHORITY')
      ..addAll({
        _fixture: temporary.path,
        'ADELE_CREDENTIAL_STORAGE_PARENT_BUS':
            Platform.environment['DBUS_SESSION_BUS_ADDRESS'] ?? '',
        'XDG_DATA_HOME': '${temporary.path}/data',
        'XDG_CONFIG_HOME': '${temporary.path}/config',
        'XDG_CACHE_HOME': '${temporary.path}/cache',
        'XDG_RUNTIME_DIR': '${temporary.path}/run',
        'GNOME_KEYRING_CONTROL': '${temporary.path}/control',
        'CI': 'true',
      });
    // Keep tooling HOME/PATH: Flutter hooks sanitize RUSTUP_HOME. Only the daemon
    // gets the disposable HOME; all credential clients get the explicit bus.
    final child = await children.start(
      'dbus-run-session',
      [
        '--config-file=${busConfig.path}',
        '--',
        dart,
        '--disable-dart-dev',
        Platform.script.toFilePath(),
        '--inside',
      ],
      environment: env,
      processGroup: true,
      interactive: true,
    );
    while (await child.lines!.moveNext().timeout(const Duration(minutes: 8))) {
      final line = child.lines!.current;
      // Never forward arbitrary native/daemon/build diagnostics.
      if (_reports.contains(line)) {
        stdout.writeln(line);
        stage = line.replaceFirst('PASS ', 'after ');
      } else if (_fixtureStages.any((name) => line == 'FAIL fixture: $name')) {
        stage = line.substring('FAIL fixture: '.length);
      }
    }
    await child.success(timeout: _timeout);
    stdout.writeln('PASS credential storage smoke');
  } on Object {
    stderr.writeln(
      'FAIL credential storage smoke at $stage (details redacted)',
    );
    exitCode = 1;
  } finally {
    await children.close();
    if (temporary != null) {
      try {
        temporary.deleteSync(recursive: true);
      } on Object {
        stderr.writeln('FAIL disposable fixture cleanup (details redacted)');
        exitCode = 1;
      }
    }
  }
}

const _reports = {
  'PASS absent bus is unavailable, not missing',
  'PASS private bus without Secret Service is unavailable, not missing',
  'PASS same-process native and application retry after initial unavailability',
  'PASS production service CRUD, byte limit, reconstruction, FIFO and close drain',
  'PASS independent native entries and reader-process persistence',
  'PASS malformed UTF-8 failure preserves exact stored bytes',
  'PASS locked existing read/write/delete fail without changing the value',
  'PASS persistence across daemon and reader-process restart',
  'PASS bound record attachment with only a nonsecret TOML reference',
  'PASS bound record reconstruction across process and daemon restart, replacement and Forget',
  'PASS real blocked native call leaves Flutter frames responsive and close pending',
  'PASS disposable credential cleanup',
};

const _fixtureStages = {
  'isolated setup',
  'absent bus',
  'no service and same-process retry',
  'native independent entries',
  'corrupt bytes',
  'locked existing entry',
  'daemon restart',
  'record attachment',
  'record reconstruction',
  'Flutter responsiveness',
  'entry cleanup',
};

Future<void> _inside(Directory root, _Children children) async {
  final env = Platform.environment;
  final fixture = env[_fixture];
  final bus = env['DBUS_SESSION_BUS_ADDRESS'];
  _require(fixture != null && Directory(fixture).isAbsolute);
  _require(Directory(fixture!).existsSync());
  _require(bus != null && bus.startsWith('unix:path=$fixture/run/'));
  _require(bus != env['ADELE_CREDENTIAL_STORAGE_PARENT_BUS']);
  _require(env['GNOME_KEYRING_CONTROL'] == '$fixture/control');
  final dart = '${env['FLUTTER_ROOT']}/bin/cache/dart-sdk/bin/dart';
  final binary =
      '${root.path}/packages/credential_store/native/target/release/credential_probe';
  final app = '${root.path}/app';
  final master = _random();
  var stage = 'isolated setup';
  Future<void> probe(
    String operation,
    String reference, {
    String? input,
    Set<int> statuses = const {0},
  }) async {
    final output = (await children.command(
      binary,
      [operation, reference],
      input: input,
      capture: true,
    )).trim();
    _require(RegExp(r'^[0-6] 1$').hasMatch(output));
    _require(statuses.contains(int.parse(output[0])));
  }

  Future<void> missing(String reference) async {
    await probe('read', reference, statuses: {1});
    await probe('contains', reference, statuses: {1});
  }

  Future<void> association(String phase) async {
    await children.command(
      '${env['FLUTTER_ROOT']}/bin/flutter',
      [
        'test',
        '--no-pub',
        '--reporter',
        'expanded',
        '--concurrency',
        '1',
        'test/credential_association_smoke_test.dart',
      ],
      directory: app,
      environment: {...env, 'ADELE_CREDENTIAL_ASSOCIATION_PHASE': phase},
      timeout: const Duration(minutes: 4),
    );
    _require(File('$fixture/association-$phase.completed').existsSync());
  }

  Future<_Child> daemon() async {
    final child = await children.start(
      'gnome-keyring-daemon',
      [
        '--foreground',
        '--components=secrets',
        '--control-directory',
        '$fixture/control',
        '--unlock',
      ],
      environment: {...env, 'HOME': '$fixture/home'},
    );
    child.process.stdin.write(master);
    await child.process.stdin.close().timeout(_timeout);
    await children.command('gdbus', [
      'wait',
      '--session',
      '--timeout',
      '10',
      'org.freedesktop.secrets',
    ]);
    _require(!child.exited);
    return child;
  }

  try {
    stage = 'absent bus';
    await children.command(
      dart,
      ['run', 'tool/credential_storage_probe.dart', '--unavailable'],
      directory: app,
      environment: {
        ...env,
        'DBUS_SESSION_BUS_ADDRESS': 'unix:path=$fixture/run/absent',
      },
      timeout: const Duration(minutes: 4),
    );
    stdout.writeln('PASS absent bus is unavailable, not missing');
    stage = 'no service and same-process retry';
    final recovery = await children.start(
      dart,
      ['run', 'tool/credential_storage_probe.dart', '--recover'],
      directory: app,
      interactive: true,
    );
    await recovery.expect('UNAVAILABLE', timeout: const Duration(minutes: 4));
    stdout.writeln(
      'PASS private bus without Secret Service is unavailable, not missing',
    );
    var keyring = await daemon();
    recovery.process.stdin.writeln('retry');
    await recovery.process.stdin.close().timeout(_timeout);
    await recovery.expect('PASS_RECOVERY');
    stdout.writeln(
      'PASS same-process native and application retry after initial unavailability',
    );
    await recovery.expect('PASS_SERVICE');
    await recovery.expect('PASS_CLEANUP');
    await recovery.success();
    stdout.writeln(
      'PASS production service CRUD, byte limit, reconstruction, FIFO and close drain',
    );

    stage = 'record attachment';
    await association('attach');
    stdout.writeln(
      'PASS bound record attachment with only a nonsecret TOML reference',
    );

    stage = 'native independent entries';
    final a = 'cred1_${_random().substring(0, 32)}';
    final b = 'cred1_${_random().substring(0, 32)}';
    final first = _random();
    final second = _random();
    final changed = _random();
    await missing(a);
    await probe('write', a, input: first);
    await probe('write', b, input: second);
    await probe('verify', a, input: first);
    await probe('verify', b, input: second);
    await probe('write', a, input: changed);
    await probe('verify', a, input: changed);
    await probe('verify', b, input: second);
    await probe('delete', b);
    await missing(b);
    await probe('verify', a, input: changed);
    stdout.writeln(
      'PASS independent native entries and reader-process persistence',
    );
    stage = 'corrupt bytes';
    await probe('corrupt', b);
    stdout.writeln('PASS malformed UTF-8 failure preserves exact stored bytes');
    stage = 'locked existing entry';
    await children.command('gdbus', [
      'call',
      '--session',
      '--dest',
      'org.freedesktop.secrets',
      '--object-path',
      '/org/freedesktop/secrets',
      '--method',
      'org.freedesktop.Secret.Service.Lock',
      "['/org/freedesktop/secrets/collection/login']",
    ]);
    for (final operation in ['read', 'contains', 'write', 'delete']) {
      await probe(
        operation,
        a,
        input: operation == 'write' ? _random() : null,
        statuses: {2, 3},
      );
    }
    stage = 'daemon restart';
    await keyring.stop();
    keyring = await daemon();
    await probe('verify', a, input: changed);
    stdout.writeln(
      'PASS locked existing read/write/delete fail without changing the value',
    );
    stdout.writeln('PASS persistence across daemon and reader-process restart');
    stage = 'record reconstruction';
    await association('reopen');
    stdout.writeln(
      'PASS bound record reconstruction across process and daemon restart, replacement and Forget',
    );
    stage = 'Flutter responsiveness';
    File('$fixture/daemon.pid').writeAsStringSync('${keyring.process.pid}');
    await children.command(
      '${env['FLUTTER_ROOT']}/bin/flutter',
      [
        'test',
        '--no-pub',
        '--reporter',
        'expanded',
        '--concurrency',
        '1',
        'test/credential_storage_responsiveness_test.dart',
      ],
      directory: app,
      environment: {
        ...env,
        'ADELE_CREDENTIAL_STORAGE_DAEMON_PID': '${keyring.process.pid}',
      },
      timeout: const Duration(minutes: 4),
    );
    _require(File('$fixture/widget.completed').existsSync());
    stdout.writeln(
      'PASS real blocked native call leaves Flutter frames responsive and close pending',
    );
    stage = 'entry cleanup';
    await probe('delete', a);
    await probe('delete', b, statuses: {0, 1});
    await missing(a);
    await missing(b);
    stdout.writeln('PASS disposable credential cleanup');
  } on Object {
    stdout.writeln('FAIL fixture: $stage');
    rethrow;
  }
}

String _random() {
  final random = Random.secure();
  return List.generate(
    32,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

bool _onPath(String executable) => (Platform.environment['PATH'] ?? '')
    .split(':')
    .any((path) => File('$path/$executable').existsSync());

void _require(bool condition) {
  if (!condition) throw StateError('Credential smoke check failed.');
}

final class _Children {
  _Children({required this.processGroups});
  final bool processGroups;
  final _children = <_Child>[];

  Future<_Child> start(
    String executable,
    List<String> args, {
    String? directory,
    Map<String, String>? environment,
    bool? processGroup,
    bool interactive = false,
    bool capture = false,
  }) async {
    final grouped = processGroup ?? processGroups;
    final process = await Process.start(
      grouped ? 'setsid' : executable,
      grouped ? ['--', executable, ...args] : args,
      workingDirectory: directory,
      environment: environment,
      includeParentEnvironment: environment == null,
    );
    final child = _Child(process, grouped, interactive, capture);
    _children.add(child);
    return child;
  }

  Future<String> command(
    String executable,
    List<String> args, {
    String? directory,
    Map<String, String>? environment,
    String? input,
    bool capture = false,
    Duration timeout = _timeout,
  }) async {
    final child = await start(
      executable,
      args,
      directory: directory,
      environment: environment,
      capture: capture,
    );
    try {
      if (input != null) child.process.stdin.write(input);
      await child.process.stdin.close().timeout(_timeout);
      await child.success(timeout: timeout);
      return child.output.toString();
    } finally {
      await child.stop();
    }
  }

  Future<void> close() async {
    // Resume every tracked process first, including the daemon if Flutter died
    // between SIGSTOP and its finally. The outer private group covers descendants
    // (Flutter workers, hook Cargo, dbus-daemon) even after their parent exits.
    for (final child in _children) {
      child.signal(ProcessSignal.sigcont);
    }
    for (final child in _children.reversed) {
      await child.stop();
    }
  }
}

final class _Child {
  _Child(this.process, this.processGroup, bool interactive, bool capture) {
    exit = process.exitCode.then((code) {
      exited = true;
      return code;
    });
    errors = process.stderr.drain<void>();
    if (interactive) {
      lines = StreamIterator(
        process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter()),
      );
      drained = Future<void>.value();
    } else {
      drained = process.stdout.forEach((bytes) {
        if (capture && output.length < 131072) {
          output.write(utf8.decode(bytes, allowMalformed: true));
        }
      });
    }
  }
  final Process process;
  final bool processGroup;
  final output = StringBuffer();
  late final Future<int> exit;
  late final Future<void> errors;
  late final Future<void> drained;
  StreamIterator<String>? lines;
  bool exited = false;
  bool stopped = false;

  Future<void> expect(String expected, {Duration timeout = _timeout}) async {
    await (() async {
      while (await lines!.moveNext()) {
        if (lines!.current == expected) return;
      }
      throw StateError('Missing fixed fixture status.');
    })().timeout(timeout);
  }

  Future<void> success({Duration timeout = _timeout}) async {
    _require(await exit.timeout(timeout) == 0);
    await Future.wait([errors, drained]).timeout(_timeout);
  }

  void signal(ProcessSignal signal) {
    if (stopped) return;
    if (processGroup) {
      Process.killPid(-process.pid, signal);
    } else if (!exited) {
      process.kill(signal);
    }
  }

  Future<void> stop() async {
    if (stopped) return;
    signal(ProcessSignal.sigcont);
    signal(ProcessSignal.sigterm);
    try {
      await exit.timeout(const Duration(seconds: 3));
    } on Object {
      signal(ProcessSignal.sigkill);
      try {
        await exit.timeout(const Duration(seconds: 3));
      } on Object {
        exitCode = 1;
      }
    } finally {
      // A group may outlive its direct child. Never leave hook/test descendants.
      if (processGroup) signal(ProcessSignal.sigkill);
      stopped = true;
      try {
        await lines?.cancel().timeout(const Duration(seconds: 1));
        await Future.wait([
          errors,
          drained,
        ]).timeout(const Duration(seconds: 1));
      } on Object {
        exitCode = 1;
      }
    }
  }
}
