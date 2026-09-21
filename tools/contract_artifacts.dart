import 'dart:io';

// Keep prerequisites runnable before generated contract consumers compile.
// ignore: avoid_relative_lib_imports
import '../packages/plugin_builder/lib/plugin_builder.dart';

Future<void> runContractCodegen({
  required Directory repositoryRoot,
  String dartExecutable = 'dart',
  List<String> options = const <String>[],
}) async {
  const stage = 'contract-generation';
  final arguments = <String>[
    'run',
    'packages/contract_codegen/bin/contract_codegen.dart',
    ...options,
  ];
  stdout.writeln('==> $stage${options.isEmpty ? '' : ' ${options.join(' ')}'}');
  final ProcessResult result;
  try {
    result = await Process.run(
      dartExecutable,
      arguments,
      workingDirectory: repositoryRoot.path,
      runInShell: Platform.isWindows,
    );
  } on ProcessException catch (error) {
    throw PluginBuildFailure('$stage could not start: $error');
  }
  final diagnostic = PluginBuildDiagnostic(
    stage: stage,
    command: <String>[dartExecutable, ...arguments],
    workingDirectory: repositoryRoot.path,
    exitCode: result.exitCode,
    stdoutText: result.stdout.toString(),
    stderrText: result.stderr.toString(),
  );
  stdout.write(diagnostic.stdoutText);
  stderr.write(diagnostic.stderrText);
  if (result.exitCode != 0) {
    throw PluginBuildFailure(
      '$stage failed with exit code ${result.exitCode}.',
      diagnostic: diagnostic,
    );
  }
}
