import 'dart:io';

import 'package:adele_desktop/development/agent/development_self_hosting_runner.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    _usage();
    return;
  }
  final DevelopmentSelfHostingOptions options;
  try {
    options = DevelopmentSelfHostingOptions.parse(arguments);
  } on DevelopmentSelfHostingUsageException catch (error) {
    stderr.writeln('ERROR: ${error.message}');
    _usage();
    exitCode = 64;
    return;
  }

  final DevelopmentSelfHostingRunnerResult result;
  try {
    result = await const DevelopmentSelfHostingRunner().run(options);
  } on DevelopmentSelfHostingOutputRootException catch (error) {
    stderr.writeln('ERROR: ${error.message}');
    exitCode = 64;
    return;
  }
  stdout.writeln('Run evidence: ${result.runDirectory.path}');
  stdout.writeln(
    'Project source: ${result.projectSource?.path ?? 'unavailable'}',
  );
  stdout.writeln(
    'Task worktree: ${result.taskWorktree?.path ?? 'unavailable'}',
  );
  stdout.writeln('ADELE Run state: ${result.runState?.name ?? 'unavailable'}');
  if (result.failure != null) stderr.writeln('FAILED: ${result.failure}');
  exitCode = result.exitCode;
}

void _usage() {
  stdout.writeln('''
Usage: dart run app/bin/adele_self_host.dart \\
  --prompt-file <path> \\
  --instructions-file <path> \\
  --task-title <text> \\
  --max-model-invocations <positive-int> \\
  --output-dir <path> \\
  [--profile chatgpt|api-key]

Runs one developer-only ADELE self-hosting experiment. The default profile is
chatgpt. Project source, Task worktree, raw journal, deterministic reports, and
Git evidence are preserved below a new run directory in --output-dir.
''');
}
