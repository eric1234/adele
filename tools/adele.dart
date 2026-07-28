import 'dart:io';

const List<({String name, String path, bool flutter})> _packages =
    <({String name, String path, bool flutter})>[
      (name: 'adele_desktop', path: 'app', flutter: true),
      (name: 'adele_plugin_api', path: 'packages/plugin_api', flutter: false),
      (name: 'adele_contract', path: 'packages/contract', flutter: false),
      (
        name: 'adele_capabilities',
        path: 'packages/capabilities',
        flutter: false,
      ),
      (name: 'plugin_runtime', path: 'packages/plugin_runtime', flutter: false),
      (name: 'plugin_builder', path: 'packages/plugin_builder', flutter: false),
      (name: 'agent_kernel', path: 'packages/agent_kernel', flutter: false),
      (name: 'workspace_demo', path: 'plugins/workspace_demo', flutter: false),
      (
        name: 'workspace_demo_contract',
        path: 'plugins/workspace_demo/packages/contract',
        flutter: false,
      ),
      (
        name: 'workspace_demo_backend',
        path: 'plugins/workspace_demo/packages/backend',
        flutter: false,
      ),
      (
        name: 'workspace_demo_frontend',
        path: 'plugins/workspace_demo/packages/frontend',
        flutter: true,
      ),
    ];

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    _usage();
    exitCode = 64;
    return;
  }

  try {
    switch (arguments.first) {
      case 'bootstrap':
        await _run('workspace dependency resolution', 'flutter', <String>[
          'pub',
          'get',
        ]);
        await _run('workspace package listing', 'dart', <String>[
          'pub',
          'workspace',
          'list',
        ]);
        return;
      case 'format':
        final bool check = arguments.skip(1).contains('--check');
        await _run('repository formatting', 'dart', <String>[
          'format',
          if (check) ...<String>['--output=none', '--set-exit-if-changed'],
          '.',
        ]);
        return;
      case 'analyze':
        await _run('repository tools', 'dart', <String>[
          'analyze',
          '--fatal-infos',
          'tools',
        ]);
        for (final package in _packages) {
          await _run(
            package.name,
            package.flutter ? 'flutter' : 'dart',
            <String>['analyze', '--fatal-infos'],
            workingDirectory: package.path,
          );
        }
        return;
      case 'test':
        await _run('adele_plugin_api', 'dart', <String>[
          'test',
        ], workingDirectory: 'packages/plugin_api');
        await _run('adele_capabilities', 'dart', <String>[
          'test',
        ], workingDirectory: 'packages/capabilities');
        await _run('adele_desktop', 'flutter', <String>[
          'test',
        ], workingDirectory: 'app');
        return;
      case 'check':
        await main(<String>['format', '--check']);
        if (exitCode != 0) return;
        await main(<String>['analyze']);
        if (exitCode != 0) return;
        await main(<String>['test']);
        return;
      case 'run':
        final String device = arguments.length > 1
            ? arguments[1]
            : _defaultDesktopDevice();
        await _run('adele_desktop', 'flutter', <String>[
          'run',
          '-d',
          device,
        ], workingDirectory: 'app');
        return;
      case 'build':
        final String target = arguments.length > 1
            ? arguments[1]
            : _defaultDesktopDevice();
        await _run('adele_desktop $target build', 'flutter', <String>[
          'build',
          target,
          '--debug',
        ], workingDirectory: 'app');
        return;
      default:
        _usage();
        exitCode = 64;
        return;
    }
  } on _CommandFailure catch (failure) {
    stderr.writeln(
      'FAILED: ${failure.label} exited with code ${failure.exitCode}.',
    );
    exitCode = failure.exitCode;
  }
}

Future<void> _run(
  String label,
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  stdout.writeln('==> $label');
  final Process process = await Process.start(
    executable,
    arguments,
    mode: ProcessStartMode.inheritStdio,
    runInShell: Platform.isWindows,
    workingDirectory: workingDirectory,
  );
  final int result = await process.exitCode;
  if (result != 0) {
    throw _CommandFailure(label, result);
  }
}

String _defaultDesktopDevice() {
  if (Platform.isLinux) return 'linux';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  throw UnsupportedError('ADELE Phase 0 supports desktop hosts only.');
}

void _usage() {
  stdout.writeln('''
Usage: dart tools/adele.dart <command>

Commands:
  bootstrap          Resolve the complete pub workspace.
  format [--check]   Format or verify formatting for all Dart files.
  analyze            Analyze every package and identify failures.
  test               Run public value tests and desktop widget tests.
  check              Verify formatting, analysis, and tests.
  run [device]       Run the desktop app (linux, macos, or windows).
  build [target]     Build a debug desktop app.
''');
}

final class _CommandFailure implements Exception {
  const _CommandFailure(this.label, this.exitCode);

  final String label;
  final int exitCode;
}
