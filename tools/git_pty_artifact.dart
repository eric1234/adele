import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

// Keep checkout preparation usable before pub workspace bootstrap.
// ignore: avoid_relative_lib_imports
import '../packages/plugin_builder/lib/plugin_builder.dart';
import 'desktop_artifact_cache.dart';

const _compilerOptions = ['-std=c11', '-O2', '-Wall', '-Wextra', '-Werror'];

/// Preprocessing accounts for the selected compiler's macros and system headers,
/// without generating machine code. Public startup configuration is not an input.
Future<Map<String, Object>> gitPtyBuildIdentity(
  Directory repositoryRoot,
) async {
  Future<String?> executable(String name, {bool optional = false}) async {
    for (final directory in Platform.environment['PATH']!.split(':')) {
      final file = File(name.contains('/') ? name : '$directory/$name');
      if (await file.exists()) return file.resolveSymbolicLinks();
    }
    if (optional) return null;
    throw PluginBuildFailure(
      'git-pty-helper toolchain executable is missing: $name',
    );
  }

  final launcher = Platform.environment['PATH']!
      .split(':')
      .map((directory) => File('$directory/cc'))
      .firstWhere((file) => file.existsSync())
      .absolute;
  final resolved = await launcher.resolveSymbolicLinks();
  final source =
      '${repositoryRoot.absolute.path}/plugins/git/packages/backend/native/git_pty_helper.c';
  Future<String> inspect(List<String> arguments) async {
    final ProcessResult result;
    try {
      result = await Process.run(
        'cc',
        arguments,
        workingDirectory: repositoryRoot.path,
      );
    } on ProcessException catch (error) {
      throw PluginBuildFailure(
        'git-pty-helper toolchain inspection could not start: $error',
      );
    }
    if (result.exitCode != 0) {
      stdout.write(result.stdout);
      stderr.write(result.stderr);
      throw PluginBuildFailure(
        'git-pty-helper toolchain inspection failed with exit code ${result.exitCode}.',
        diagnostic: PluginBuildDiagnostic(
          stage: 'git-pty-toolchain-inspection',
          command: ['cc', ...arguments],
          workingDirectory: repositoryRoot.path,
          exitCode: result.exitCode,
          stdoutText: result.stdout.toString(),
          stderrText: result.stderr.toString(),
        ),
      );
    }
    return result.stdout.toString();
  }

  final toolchain = <String>[resolved];
  final locations = <String, String>{};
  for (final name in ['cc1', 'collect2', 'as', 'ld']) {
    final location = (await inspect(['-print-prog-name=$name'])).trim();
    final selected = await executable(
      location,
      optional: name == 'cc1' || name == 'collect2',
    );
    locations[name] = selected ?? location;
    if (selected != null) toolchain.add(selected);
  }
  for (final name in [
    'crt1.o',
    'Scrt1.o',
    'crti.o',
    'crtn.o',
    'crtbegin.o',
    'crtbeginS.o',
    'crtend.o',
    'crtendS.o',
    'libgcc.a',
    'libgcc_s.so',
    'libgcc_s.so.1',
    'libc.so',
    'libc.so.6',
    'libc_nonshared.a',
    'libutil.so',
    'libutil.a',
  ]) {
    final location = (await inspect(['-print-file-name=$name'])).trim();
    locations[name] = location;
    // GCC returns the requested bare name when that optional variant is absent.
    // Its presence later changes this location map as well as the file hashes.
    if (location != name) {
      toolchain.add(await File(location).resolveSymbolicLinks());
    }
  }
  final preprocessed = await inspect(['-E', ..._compilerOptions, source]);
  final inputFiles = <String>{
    ...toolchain,
    launcher.path,
    source,
    '${repositoryRoot.absolute.path}/tools/git_pty_artifact.dart',
    '${repositoryRoot.absolute.path}/tools/desktop_artifact_cache.dart',
  };
  for (final match in RegExp(
    r'^#\s+\d+\s+("(?:[^"\\]|\\.)*")',
    multiLine: true,
  ).allMatches(preprocessed)) {
    final path = jsonDecode(match[1]!) as String;
    if (path.startsWith('<') && path.endsWith('>')) continue;
    inputFiles.add(
      File.fromUri(repositoryRoot.absolute.uri.resolveUri(Uri.file(path))).path,
    );
  }
  final orderedInputs = inputFiles.toList()..sort();
  return {
    'platform': '${Platform.operatingSystem}/${Abi.current()}',
    'inputFiles': orderedInputs,
    'compiler': await hashBuildFiles(orderedInputs),
    'locations': locations,
    'version': await inspect(['--version']),
    'preprocessed': await digestJson(preprocessed),
    'arguments': [..._compilerOptions, source, '-o', '<artifact>', '-lutil'],
    'environment': {
      for (final key in [
        'PATH',
        'CPATH',
        'C_INCLUDE_PATH',
        'LIBRARY_PATH',
        'COMPILER_PATH',
        'GCC_EXEC_PREFIX',
        'SOURCE_DATE_EPOCH',
        'LD_RUN_PATH',
      ])
        key: Platform.environment[key],
    },
  };
}

/// Build-time only. Runtime receives this prepared executable's absolute path.
Future<void> prepareGitPtyHelper({
  required Directory repositoryRoot,
  required File output,
  String compiler = 'cc',
}) async {
  if (!Platform.isLinux || Abi.current() != Abi.linuxX64) {
    throw UnsupportedError('The Git PTY helper currently supports Linux x64.');
  }
  await output.parent.create(recursive: true);
  final arguments = <String>[
    ..._compilerOptions,
    '${repositoryRoot.path}/plugins/git/packages/backend/native/'
        'git_pty_helper.c',
    '-o',
    output.absolute.path,
    '-lutil',
  ];
  late final ProcessResult result;
  try {
    result = await Process.run(
      compiler,
      arguments,
      workingDirectory: repositoryRoot.path,
    );
  } on ProcessException catch (error) {
    throw PluginBuildFailure(
      'git-pty-helper-compilation could not start: $error',
    );
  }
  if (result.exitCode != 0) {
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    throw PluginBuildFailure(
      'git-pty-helper-compilation failed with exit code ${result.exitCode}',
      diagnostic: PluginBuildDiagnostic(
        stage: 'git-pty-helper-compilation',
        command: [compiler, ...arguments],
        workingDirectory: repositoryRoot.path,
        exitCode: result.exitCode,
        stdoutText: result.stdout.toString(),
        stderrText: result.stderr.toString(),
      ),
    );
  }
  if (!await output.exists() ||
      await output.length() == 0 ||
      (await output.stat()).mode & 0x49 == 0) {
    throw const PluginBuildFailure(
      'git-pty-helper-compilation produced no executable artifact.',
    );
  }
}
