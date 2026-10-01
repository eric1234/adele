import 'dart:convert';
import 'dart:io';

const codeForgeProbeVersion = '10.14.0';
const codeForgeProbeSha256 =
    'bddb3fe2001e4dd1653b32fc2752b9d4f60c7cb78f2a02165ea45ee60a867b61';
const codeForgeProbeRust = '1.93.0';

/// This is a rejected-candidate experiment, never application preparation.
Future<int> runCodeEditorProbe({
  required Directory repository,
  required Directory output,
  required bool verifyKnownDefects,
}) async {
  if (!Platform.isLinux) {
    throw UnsupportedError('The CodeForge probe supports Linux x64 only.');
  }
  if (output.existsSync()) {
    throw ArgumentError('Probe output must not already exist: ${output.path}');
  }
  final pin =
      jsonDecode(File('${repository.path}/toolchain.json').readAsStringSync())
          as Map<String, Object?>;
  final version = await Process.run('flutter', [
    '--version',
    '--machine',
  ], workingDirectory: repository.path);
  if (version.exitCode != 0) throw StateError('${version.stderr}');
  final sdk = jsonDecode(version.stdout as String) as Map<String, Object?>;
  validateCodeEditorProbeToolchain(pin, sdk);
  if (Platform.version.split(' ').first != pin['dart']) {
    throw StateError('Run this probe with the bundled pinned Dart SDK.');
  }
  // Resolve before leaving the checkout: asdf may select a different SDK in /tmp.
  final flutter = '${sdk['flutterRoot']}/bin/flutter';
  final dart = '${sdk['flutterRoot']}/bin/cache/dart-sdk/bin/dart';
  output.createSync(recursive: true);
  final logs = Directory('${output.path}/logs')..createSync();
  stdout.writeln('CodeForge rejected-candidate evidence: ${output.path}');
  var stage = 'preparation';
  int? testExitCode;
  Object? failure;

  Future<ProcessResult> run(
    String label,
    String executable,
    List<String> arguments, {
    String? cwd,
    Map<String, String>? environment,
    bool allowFailure = false,
    bool quiet = false,
    int seconds = 600,
  }) async {
    stage = label;
    stdout.writeln('[$label] $executable ${arguments.join(' ')}');
    final result = await Process.run(
      'timeout',
      ['--kill-after=10s', '${seconds}s', executable, ...arguments],
      workingDirectory: cwd ?? output.path,
      environment: environment,
      includeParentEnvironment: environment == null,
    );
    File('${logs.path}/$label.log').writeAsStringSync(
      'exit=${result.exitCode}\n${result.stdout}\n${result.stderr}',
    );
    if (!quiet) {
      stdout.write(result.stdout);
      stderr.write(result.stderr);
    }
    if (!allowFailure && result.exitCode != 0) {
      throw StateError('$label exited ${result.exitCode}; see ${logs.path}');
    }
    return result;
  }

  try {
    final arch = await run('architecture', 'uname', ['-m']);
    if ((arch.stdout as String).trim() != 'x86_64') {
      throw UnsupportedError('The CodeForge probe supports Linux x64 only.');
    }
    await run('rust', 'rustup', ['run', codeForgeProbeRust, 'rustc', '-Vv']);
    await run('cargo', 'rustup', ['run', codeForgeProbeRust, 'cargo', '-V']);
    File(
      '${logs.path}/flutter.json',
    ).writeAsStringSync(version.stdout as String);
    final archive = '${output.path}/code_forge-$codeForgeProbeVersion.tar.gz';
    await run('download', 'curl', [
      '--fail',
      '--location',
      '--output',
      archive,
      'https://pub.dev/api/archives/code_forge-$codeForgeProbeVersion.tar.gz',
    ]);
    final checksum = await run('checksum', 'sha256sum', [archive]);
    if (!(checksum.stdout as String).startsWith('$codeForgeProbeSha256 ')) {
      throw StateError('CodeForge archive checksum mismatch.');
    }
    final source = Directory('${output.path}/code_forge')..createSync();
    await run('extract', 'tar', ['-xzf', archive, '-C', source.path]);
    final fixtures = '${repository.path}/tools/code_editor_probe/fixtures';
    await run('compatibility-patch', 'git', [
      'apply',
      '--recount',
      '$fixtures/compatibility.patch',
    ], cwd: source.path);
    File('${source.path}/cargokit/build_tool/runner.lock').writeAsStringSync(
      File(
        '$fixtures/cargokit_runner.lock.template',
      ).readAsStringSync().replaceAll(
        '"@CODEFORGE_BUILD_TOOL@"',
        jsonEncode('${source.path}/cargokit/build_tool'),
      ),
    );
    final cargoLock = File('${source.path}/rust/Cargo.lock').readAsStringSync();
    await run('rust-dependencies', 'rustup', [
      'run',
      codeForgeProbeRust,
      'cargo',
      'tree',
      '--locked',
      '--target',
      'x86_64-unknown-linux-gnu',
      '--manifest-path',
      '${source.path}/rust/Cargo.toml',
    ], quiet: true);
    final app = '${output.path}/probe';
    await run('create', flutter, [
      'create',
      '--platforms=linux',
      '--empty',
      '--no-pub',
      '--project-name',
      'adele_codeforge_probe',
      app,
    ]);
    for (final entry in {
      'pubspec.yaml.template': 'pubspec.yaml',
      'pubspec.lock': 'pubspec.lock',
      'main.dart.template': 'lib/main.dart',
      'editor_gate_test.dart.template': 'test/editor_gate_test.dart',
    }.entries) {
      final target = File('$app/${entry.value}');
      target.parent.createSync(recursive: true);
      File('$fixtures/${entry.key}').copySync(target.path);
    }
    await run('pub', flutter, ['pub', 'get', '--enforce-lockfile'], cwd: app);
    await run('format', dart, [
      'format',
      '--output=none',
      '--set-exit-if-changed',
      'lib/main.dart',
      'test/editor_gate_test.dart',
    ], cwd: app);
    await run('analysis', flutter, [
      'analyze',
      '--no-pub',
      '--fatal-infos',
    ], cwd: app);
    await run(
      'profile-build',
      flutter,
      ['build', 'linux', '--profile', '--no-pub', '--verbose'],
      cwd: app,
      environment: {
        ...Platform.environment,
        // Compiler-recommended worker stack after a proc-macro2 compiler crash.
        'RUST_MIN_STACK': '16777216',
      },
      quiet: true,
    );
    if (File('${source.path}/rust/Cargo.lock').readAsStringSync() !=
        cargoLock) {
      throw StateError('The native build modified the upstream Cargo lock.');
    }
    final bundle = '$app/build/linux/x64/profile/bundle';
    final library = File('$bundle/lib/libcode_forge.so');
    if (!library.existsSync()) {
      throw StateError('Native library was not bundled.');
    }
    await run('native-artifact', 'sha256sum', [library.path]);
    await run('native-linkage', 'readelf', ['-d', library.path], quiet: true);
    final runtime = Directory('${output.path}/runtime')..createSync();
    final runtimeEnvironment = codeEditorProbeRuntimeEnvironment(
      Platform.environment,
    );
    final launch = ['-a', '$bundle/adele_codeforge_probe'];
    final smoke = await run(
      'profile-run',
      'xvfb-run',
      launch,
      cwd: runtime.path,
      environment: runtimeEnvironment,
      seconds: 45,
    );
    if (!(smoke.stdout as String).contains('CODEFORGE_PROBE_COMPLETE')) {
      throw StateError('Profile process did not finish its editor checks.');
    }
    final unavailable = '${library.path}.unavailable';
    library.renameSync(unavailable);
    try {
      final missing = await run(
        'missing-library',
        'xvfb-run',
        launch,
        cwd: runtime.path,
        environment: runtimeEnvironment,
        seconds: 45,
        allowFailure: true,
      );
      validateCodeEditorProbeMissingLibrary(missing);
    } finally {
      File(unavailable).renameSync(library.path);
    }
    final tests = await run(
      'native-tests',
      flutter,
      [
        'test',
        '--no-pub',
        '--concurrency',
        '1',
        '--reporter',
        'expanded',
        if (verifyKnownDefects)
          '--dart-define=ADELE_EXPECT_CODEFORGE_DEFECTS=true',
        'test/editor_gate_test.dart',
      ],
      cwd: app,
      environment: {
        ...Platform.environment,
        'FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR': '$bundle/lib',
      },
      allowFailure: true,
    );
    testExitCode = tests.exitCode;
    stdout.writeln(
      'E1 INCOMPLETE: this is only a native candidate experiment. '
      '${verifyKnownDefects ? 'Known-defect assertions are enabled, not acceptance tests.' : 'The fidelity gate asserts correct behavior and is expected to fail.'}',
    );
    return tests.exitCode;
  } catch (error) {
    failure = error;
    rethrow;
  } finally {
    File('${logs.path}/result.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'codeForge': codeForgeProbeVersion,
        'archiveSha256': codeForgeProbeSha256,
        'rust': codeForgeProbeRust,
        'mode': verifyKnownDefects ? 'known-defect-reproduction' : 'gate',
        'lastStage': stage,
        'failure': failure?.toString(),
        'testExitCode': testExitCode,
        'e1Complete': false,
        'preparedEvcImplemented': false,
      }),
    );
  }
}

void validateCodeEditorProbeMissingLibrary(ProcessResult result) {
  final output = result.stdout as String;
  if (result.exitCode != 1 ||
      !output.contains('CODEFORGE_INIT_FAILED') ||
      output.contains('CODEFORGE_FRB_INIT_RETURNED')) {
    throw StateError('Missing native library did not fail during FRB loading.');
  }
}

void validateCodeEditorProbeToolchain(
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

Map<String, String> codeEditorProbeRuntimeEnvironment(
  Map<String, String> environment,
) => Map.of(environment)
  ..remove('LD_LIBRARY_PATH')
  ..remove('LD_PRELOAD')
  ..remove('FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR')
  ..['PATH'] = '/usr/bin:/bin';
