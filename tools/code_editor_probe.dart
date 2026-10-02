import 'dart:convert';
import 'dart:io';

const codeForgeProbeVersion = '10.14.0';
const codeForgeProbeSha256 =
    'bddb3fe2001e4dd1653b32fc2752b9d4f60c7cb78f2a02165ea45ee60a867b61';
const codeForgeProbeRust = '1.93.0';

/// Isolated investigation, never application preparation or E1 acceptance.
Future<int> runCodeEditorProbe({
  required Directory repository,
  required Directory output,
  required bool verifyKnownDefects,
  String? flutterExecutable,
  bool upstreamControl = false,
  bool correctnessPatch = false,
  bool investigate = false,
  bool prepareOnly = false,
}) async {
  if (upstreamControl && (flutterExecutable == null || correctnessPatch)) {
    throw ArgumentError(
      'Upstream control requires --flutter and forbids --correctness-patch.',
    );
  }
  if (verifyKnownDefects && (correctnessPatch || investigate || prepareOnly)) {
    throw ArgumentError(
      '--verify-known-defects is only the unpatched 10.14.0 baseline reproduction.',
    );
  }
  if (!Platform.isLinux) {
    throw UnsupportedError('The CodeForge probe supports Linux x64 only.');
  }
  if (output.existsSync()) {
    throw ArgumentError('Probe output must not already exist: ${output.path}');
  }
  final pin =
      jsonDecode(File('${repository.path}/toolchain.json').readAsStringSync())
          as Map<String, Object?>;
  final version = await Process.run(flutterExecutable ?? 'flutter', [
    '--version',
    '--machine',
  ], workingDirectory: repository.path);
  if (version.exitCode != 0) throw StateError('${version.stderr}');
  final sdk = jsonDecode(version.stdout as String) as Map<String, Object?>;
  if (upstreamControl) {
    validateCodeEditorUpstreamSdk(sdk);
  } else {
    validateCodeEditorProbeToolchain(pin, sdk);
  }
  if (Platform.version.split(' ').first != pin['dart']) {
    throw StateError('Run this probe with the bundled pinned Dart SDK.');
  }
  // Resolve before leaving the checkout: asdf may select a different SDK in /tmp.
  final flutter = '${sdk['flutterRoot']}/bin/flutter';
  final dart = '${sdk['flutterRoot']}/bin/cache/dart-sdk/bin/dart';
  final environment = {
    ...Platform.environment,
    'FLUTTER_ROOT': sdk['flutterRoot'] as String,
    'RUST_MIN_STACK': '16777216',
  };
  final configuration = upstreamControl
      ? 'upstream-unmodified'
      : correctnessPatch
      ? 'adele-pin-causal-patch'
      : 'adele-pin-compatibility-only';
  output.createSync(recursive: true);
  final logs = Directory('${output.path}/logs')..createSync();
  stdout.writeln('CodeForge $configuration evidence: ${output.path}');
  var stage = 'preparation';
  int? testExitCode;
  Object? failure;

  Future<ProcessResult> run(
    String label,
    String executable,
    List<String> arguments, {
    String? cwd,
    Map<String, String>? processEnvironment,
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
      environment: processEnvironment ?? environment,
      includeParentEnvironment: false,
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
    if (upstreamControl) {
      // Upstream asks rustup for "stable". Select it locally without patching
      // package source or altering the developer's default/stable toolchain.
      final compiler = await run('rust-path', 'rustup', [
        'which',
        '--toolchain',
        codeForgeProbeRust,
        'rustc',
      ]);
      final toolchain = File((compiler.stdout as String).trim()).parent.parent;
      final originalHome = await run('rustup-original-home', 'rustup', [
        'show',
        'home',
      ]);
      final launchers = [
        if (environment['CARGO_HOME'] != null)
          '${environment['CARGO_HOME']}/bin/rustup',
        '${environment['HOME']}/.cargo/bin/rustup',
        '${(originalHome.stdout as String).trim()}/bin/rustup',
      ].map(File.new).where((file) => file.existsSync()).toList();
      if (launchers.isEmpty) {
        throw StateError(
          'Cannot locate a real rustup launcher outside PATH shims.',
        );
      }
      final rustup = launchers.first.resolveSymbolicLinksSync();
      environment['PATH'] =
          '${File(rustup).parent.path}:${environment['PATH']}';
      final localRustup = Directory('${output.path}/rustup/toolchains')
        ..createSync(recursive: true);
      Link(
        '${localRustup.path}/stable-x86_64-unknown-linux-gnu',
      ).createSync(toolchain.path);
      environment['RUSTUP_HOME'] = localRustup.parent.path;
      final isolatedHome = await run('rustup-isolated-home', rustup, [
        'show',
        'home',
      ]);
      if ((isolatedHome.stdout as String).trim() != localRustup.parent.path) {
        throw StateError('Rustup did not honor the isolated compiler home.');
      }
      await run('rust-control-identity', rustup, [
        'run',
        'stable',
        'rustc',
        '-Vv',
      ]);
      // Keep normal published resolution isolated from the developer pub cache.
      environment['PUB_CACHE'] = '${output.path}/pub-cache';
    }
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
    if (!upstreamControl) {
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
      if (correctnessPatch) {
        await run('correctness-patch', 'git', [
          'apply',
          '--recount',
          '$fixtures/correctness.patch',
        ], cwd: source.path);
      }
    }
    final cargoLock = File('${source.path}/rust/Cargo.lock').readAsStringSync();
    await run('rust-dependencies', 'rustup', [
      'run',
      upstreamControl ? 'stable' : codeForgeProbeRust,
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
      '../smoke_settlement.dart': 'lib/smoke_settlement.dart',
      'editor_gate_test.dart.template': 'test/editor_gate_test.dart',
      'interactive.dart.template': 'lib/interactive.dart',
      'interactive_probe_test.dart.template':
          'test/interactive_probe_test.dart',
      if (investigate)
        'investigation_test.dart.template': 'test/investigation_test.dart',
      if (investigate)
        'selected_composition_test.dart.template':
            'test/selected_composition_test.dart',
    }.entries) {
      if (upstreamControl && entry.key == 'pubspec.lock') continue;
      final target = File('$app/${entry.value}');
      target.parent.createSync(recursive: true);
      File('$fixtures/${entry.key}').copySync(target.path);
    }
    if (upstreamControl) {
      final manifest = File('$app/pubspec.yaml');
      manifest.writeAsStringSync(
        manifest.readAsStringSync().replaceFirst(
          '  code_forge:\n    path: ../code_forge',
          '  code_forge: $codeForgeProbeVersion\n  flutter_rust_bridge: 2.13.0',
        ),
      );
    }
    await run('pub', flutter, [
      'pub',
      'get',
      if (!upstreamControl) '--enforce-lockfile',
    ], cwd: app);
    File('$app/pubspec.lock').copySync('${logs.path}/pubspec.lock');
    final nativeSource = upstreamControl
        ? '${environment['PUB_CACHE']}/hosted/pub.dev/code_forge-$codeForgeProbeVersion'
        : source.path;
    if (upstreamControl) {
      await run('unmodified-package', 'diff', [
        '-qr',
        source.path,
        nativeSource,
      ]);
    }
    await run('source-identities', 'sha256sum', [
      '$nativeSource/lib/code_forge/controller.dart',
      '$nativeSource/lib/code_forge/undo_redo.dart',
      '$nativeSource/lib/code_forge/code_area.dart',
      '$nativeSource/lib/src/rust/frb_generated.dart',
      '$nativeSource/rust/src/frb_generated.rs',
      '$nativeSource/rust/Cargo.lock',
    ]);
    await run('format', dart, [
      'format',
      '--output=none',
      '--set-exit-if-changed',
      'lib',
      'test',
    ], cwd: app);
    await run('analysis', flutter, [
      'analyze',
      '--no-pub',
      '--fatal-infos',
    ], cwd: app);
    await run(
      'profile-build',
      flutter,
      codeEditorProbeBuildArguments(sdk, configuration: configuration),
      cwd: app,
      quiet: true,
    );
    if (File('$nativeSource/rust/Cargo.lock').readAsStringSync() != cargoLock) {
      throw StateError('The native build modified the upstream Cargo lock.');
    }
    final bundle = '$app/build/linux/x64/profile/bundle';
    final runnerLock = File(
      '$app/build/linux/x64/profile/plugins/code_forge/cargokit_build/tool/pubspec.lock',
    );
    runnerLock.copySync('${logs.path}/cargokit-runner.lock');
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
      processEnvironment: runtimeEnvironment,
      seconds: 45,
      allowFailure: true,
    );
    validateCodeEditorProbeSmoke(smoke);
    final unavailable = '${library.path}.unavailable';
    library.renameSync(unavailable);
    try {
      final missing = await run(
        'missing-library',
        'xvfb-run',
        launch,
        cwd: runtime.path,
        processEnvironment: runtimeEnvironment,
        seconds: 45,
        allowFailure: true,
      );
      validateCodeEditorProbeMissingLibrary(missing);
    } finally {
      File(unavailable).renameSync(library.path);
    }
    stdout.writeln(
      'Interactive launch: $bundle/adele_codeforge_probe --interactive',
    );
    await run(
      'interactive-ui-tests',
      flutter,
      [
        'test',
        '--no-pub',
        '--concurrency',
        '1',
        '--reporter',
        'expanded',
        'test/interactive_probe_test.dart',
      ],
      cwd: app,
      processEnvironment: {
        ...environment,
        'FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR': '$bundle/lib',
      },
    );
    if (prepareOnly) {
      stdout.writeln(
        'Preparation and native smoke completed; editor correctness tests NOT RUN.',
      );
      return 0;
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
        investigate
            ? 'test/investigation_test.dart'
            : 'test/editor_gate_test.dart',
        if (investigate) 'test/selected_composition_test.dart',
      ],
      cwd: app,
      processEnvironment: {
        ...environment,
        'FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR': '$bundle/lib',
      },
      allowFailure: true,
    );
    testExitCode = tests.exitCode;
    stdout.writeln(
      'E1 INCOMPLETE: this is only a native candidate experiment. '
      '${verifyKnownDefects ? 'Versioned known-observation assertions are enabled, not acceptance tests.' : 'Correct-behavior assertions are enabled; a failed assertion is not a verdict on the entire component.'}',
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
        'configuration': configuration,
        'flutter': sdk,
        'mode': prepareOnly
            ? 'prepare-only'
            : verifyKnownDefects
            ? 'known-defect-reproduction'
            : investigate
            ? 'investigation'
            : 'gate',
        'lastStage': stage,
        'failure': failure?.toString(),
        'testExitCode': testExitCode,
        'e1Complete': false,
        'preparedEvcImplemented': false,
      }),
    );
  }
}

List<String> codeEditorProbeBuildArguments(
  Map<String, Object?> sdk, {
  required String configuration,
}) => [
  'build',
  'linux',
  '--profile',
  '--no-pub',
  '--verbose',
  '--dart-define=ADELE_CODEFORGE_CONFIGURATION=$configuration',
  '--dart-define=FLUTTER_VERSION=${sdk['frameworkVersion'] as String}',
];

void validateCodeEditorProbeSmoke(ProcessResult result) =>
    _validateCodeEditorProbeResult(result, missingLibrary: false);

void validateCodeEditorProbeMissingLibrary(ProcessResult result) =>
    _validateCodeEditorProbeResult(result, missingLibrary: true);

void _validateCodeEditorProbeResult(
  ProcessResult result, {
  required bool missingLibrary,
}) {
  final label = missingLibrary ? 'Missing-library process' : 'Profile process';
  final code = result.exitCode;
  if (code == 124) {
    throw StateError('$label timed out (exit 124).');
  }
  if (code < 0 || (code > 128 && code <= 192)) {
    final signal = code < 0 ? -code : code - 128;
    throw StateError(
      '$label terminated by signal $signal (exit $code; '
      'SIGKILL may also indicate timeout escalation).',
    );
  }
  final output = '${result.stdout}\n${result.stderr}';
  final failures = RegExp(
    r'\bCODEFORGE_[A-Z0-9_]*FAILED\b',
  ).allMatches(output).map((match) => match.group(0)!).toSet();
  if (missingLibrary) {
    if (code != 1) {
      throw StateError('$label exited $code; expected load-failure exit 1.');
    }
    if (failures.length != 1 ||
        !failures.contains('CODEFORGE_INIT_FAILED') ||
        output.contains('CODEFORGE_FRB_INIT_RETURNED') ||
        output.contains('CODEFORGE_NATIVE_INITIALIZED') ||
        output.contains('CODEFORGE_PROBE_COMPLETE')) {
      throw StateError(
        'Missing native library did not fail during FRB loading.',
      );
    }
    return;
  }
  if (failures.isNotEmpty) {
    throw StateError(
      '$label reported explicit failure: ${failures.join(', ')}.',
    );
  }
  if (code != 0) {
    throw StateError('$label exited $code.');
  }
  if (!(result.stdout as String).contains('CODEFORGE_PROBE_COMPLETE')) {
    throw StateError(
      '$label did not finish its editor checks (missing completion).',
    );
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

void validateCodeEditorUpstreamSdk(Map<String, Object?> sdk) {
  final version = RegExp(
    r'^3\.(\d+)\.(\d+)$',
  ).firstMatch('${sdk['dartSdkVersion']}');
  if (version == null ||
      int.parse(version[1]!) < 13 ||
      (int.parse(version[1]!) == 13 && int.parse(version[2]!) < 2)) {
    throw StateError(
      'The unmodified package declares Dart ^3.13.2; '
      'selected SDK has ${sdk['dartSdkVersion']}. This is not an editing result.',
    );
  }
}

Map<String, String> codeEditorProbeRuntimeEnvironment(
  Map<String, String> environment,
) => Map.of(environment)
  ..remove('LD_LIBRARY_PATH')
  ..remove('LD_PRELOAD')
  ..remove('FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR')
  ..['PATH'] = '/usr/bin:/bin';
