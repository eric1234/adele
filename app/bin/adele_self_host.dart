import 'dart:io';

// This launcher must compile even when every generated contract part is absent.
// ignore: avoid_relative_lib_imports
import '../../packages/plugin_builder/lib/plugin_builder.dart';
import '../../tools/contract_artifacts.dart';

Future<void> main(List<String> arguments) async {
  final repository = Directory.fromUri(Platform.script.resolve('../../'));
  try {
    await runContractCodegen(
      repositoryRoot: repository,
      dartExecutable: Platform.resolvedExecutable,
    );
  } on PluginBuildFailure catch (failure) {
    stderr.writeln('FAILED: $failure');
    exitCode = failure.diagnostic?.exitCode ?? 1;
    return;
  }
  final process = await Process.start(Platform.resolvedExecutable, <String>[
    File.fromUri(repository.uri.resolve('app/tool/self_hosting/cli.dart')).path,
    ...arguments,
  ], mode: ProcessStartMode.inheritStdio);
  exitCode = await process.exitCode;
}
