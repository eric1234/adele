import 'dart:convert';
import 'dart:io';

import 'code_editor_dependency.dart';
import 'code_editor_smoke_support.dart';

/// Builds the application package, not a generated probe or a substitute editor.
/// Preparation is serial with the profile build; runtime needs only the bundle.
Future<void> runCodeEditorSmoke(
  Directory repository, {
  bool prepareOnly = false,
}) async {
  if (!Platform.isLinux) {
    throw UnsupportedError('The integrated editor smoke supports Linux x64.');
  }
  repository = repository.absolute;
  final pin =
      jsonDecode(await File('${repository.path}/toolchain.json').readAsString())
          as Map<String, dynamic>;
  // Derive Flutter from this pinned bundled Dart, not a potentially different
  // FLUTTER_ROOT inherited from a shell or version-manager shim.
  final bundledRoot = File(
    Platform.resolvedExecutable,
  ).parent.parent.parent.parent.parent.path;
  final version = await Process.run(
    '$bundledRoot/bin/flutter',
    ['--version', '--machine'],
    workingDirectory: repository.path,
    environment: {'FLUTTER_ROOT': bundledRoot},
  );
  if (version.exitCode != 0) throw StateError('${version.stderr}');
  final sdk = jsonDecode(version.stdout as String) as Map<String, dynamic>;
  validateCodeEditorSmokeToolchain(pin, sdk);
  if (Platform.version.split(' ').first != pin['dart']) {
    throw StateError('Run editor-smoke with the pinned bundled Dart SDK.');
  }
  final architecture = await Process.run('uname', ['-m']);
  if (architecture.exitCode != 0 ||
      (architecture.stdout as String).trim() != 'x86_64') {
    throw UnsupportedError('The integrated editor smoke supports Linux x64.');
  }
  final flutterRoot = sdk['flutterRoot'] as String;
  final environment = {
    ...Platform.environment,
    'FLUTTER_ROOT': flutterRoot,
    'RUST_MIN_STACK': '16777216',
  };
  final app = Directory('${repository.path}/app');
  final output = Directory('${app.path}/build/code_editor_smoke');
  await output.create(recursive: true);
  final logs = Directory('${output.path}/logs');
  await logs.create(recursive: true);
  var stage = 'source-verification';
  Object? failure;

  Future<ProcessResult> run(
    String label,
    String executable,
    List<String> arguments, {
    Directory? cwd,
    Map<String, String>? env,
    bool allowFailure = false,
    int seconds = 600,
  }) async {
    stage = label;
    stdout.writeln('[$label] $executable ${arguments.join(' ')}');
    final result = await Process.run(
      'timeout',
      ['--kill-after=10s', '${seconds}s', executable, ...arguments],
      workingDirectory: (cwd ?? app).path,
      environment: env ?? environment,
      includeParentEnvironment: false,
    );
    await File('${logs.path}/$label.log').writeAsString(
      'exit=${result.exitCode}\n${result.stdout}\n${result.stderr}',
    );
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (!allowFailure && result.exitCode != 0) {
      throw StateError('$label exited ${result.exitCode}; see ${logs.path}.');
    }
    return result;
  }

  try {
    await withCodeEditorSource(repository, (source) async {
      final metadata =
          jsonDecode(
                await File(
                  '${repository.path}/third_party/code_forge/preparation.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final prepared =
          jsonDecode(
                await File(
                  '${source.path}/.adele-preparation.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      await run('prepare-evc', '$flutterRoot/bin/flutter', [
        'test',
        '--no-pub',
        '--concurrency',
        '1',
        'tool/code_editor_smoke/prepare_test.dart',
      ]);
      final artifact = File('${output.path}/editor_frontend.evc');
      if (!await artifact.exists() || await artifact.length() == 0) {
        throw StateError('Frontend preparation produced no EVC artifact.');
      }
      await run('profile-build', '$flutterRoot/bin/flutter', [
        'build',
        'linux',
        '--profile',
        '--no-pub',
        '--target=tool/code_editor_smoke/main.dart',
        '--dart-define=ADELE_CODE_EDITOR_IDENTITY=${codeEditorSmokeIdentity(metadata, preparationIdentity: prepared['identity'] as String)}',
      ]);
      final bundle = Directory('${app.path}/build/linux/x64/profile/bundle');
      final library = File('${bundle.path}/lib/libcode_forge.so');
      final executable = File('${bundle.path}/adele_desktop');
      if (!await library.exists() ||
          await library.length() == 0 ||
          !await executable.exists()) {
        throw StateError(
          'Profile build did not package the editor and executable.',
        );
      }
      await artifact.copy('${bundle.path}/data/editor_frontend.evc');
      await run('native-artifact', 'sha256sum', [library.path]);
      stdout.writeln('Manual editor: ${executable.path} --interactive');
      if (prepareOnly) {
        stdout.writeln(
          'Bundle prepared; automated runtime checks were not run.',
        );
        return;
      }
      final runtime = await Directory.systemTemp.createTemp(
        'adele-editor-smoke-',
      );
      final runtimeEnvironment = codeEditorSmokeRuntimeEnvironment(environment);
      try {
        final launch = ['-a', '-s', '-screen 0 1440x1000x24', executable.path];
        final smoke = await run(
          'profile-run',
          'xvfb-run',
          launch,
          cwd: runtime,
          env: runtimeEnvironment,
          seconds: 90,
          allowFailure: true,
        );
        validateCodeEditorSmoke(smoke);
        final unavailable = '${library.path}.unavailable';
        await library.rename(unavailable);
        try {
          final missing = await run(
            'missing-library',
            'xvfb-run',
            launch,
            cwd: runtime,
            env: runtimeEnvironment,
            seconds: 45,
            allowFailure: true,
          );
          validateCodeEditorMissingLibrary(missing);
        } finally {
          await File(unavailable).rename(library.path);
        }
      } finally {
        await runtime.delete(recursive: true);
      }
    });
    // Revalidate after consumption, without reentering the held source lease.
    await prepareCodeEditorSource(repository);
  } catch (error) {
    failure = error;
    rethrow;
  } finally {
    await File('${logs.path}/result.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'prepareOnly': prepareOnly,
        'lastStage': stage,
        'failure': failure?.toString(),
        'flutter': sdk,
      }),
    );
  }
}

/// Embedded build identity, derived from the maintained preparation manifest.
String codeEditorSmokeIdentity(
  Map<String, dynamic> metadata, {
  required String preparationIdentity,
}) =>
    'CodeForge ${metadata['version']} | archive ${metadata['archiveSha256']} | '
    'patches ${(metadata['patches'] as List).join(', ')} | '
    'FRB ${metadata['flutterRustBridge']} | Rust ${metadata['rust']} | '
    'prepared $preparationIdentity';
