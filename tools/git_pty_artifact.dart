import 'dart:ffi';
import 'dart:io';

// Keep checkout preparation usable before pub workspace bootstrap.
// ignore: avoid_relative_lib_imports
import '../packages/plugin_builder/lib/plugin_builder.dart';

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
    '-std=c11',
    '-O2',
    '-Wall',
    '-Wextra',
    '-Werror',
    '${repositoryRoot.path}/plugins/git_environment/packages/backend/native/'
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
  if (!await output.exists() || await output.length() == 0) {
    throw const PluginBuildFailure(
      'git-pty-helper-compilation produced no executable artifact.',
    );
  }
}
