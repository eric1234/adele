import 'dart:io';

const List<({String name, String path, bool flutter})>
_packages = <({String name, String path, bool flutter})>[
  (name: 'adele_desktop', path: 'app', flutter: true),
  (name: 'adele_plugin_api', path: 'packages/plugin_api', flutter: false),
  (name: 'adele_contract', path: 'packages/contract', flutter: false),
  (name: 'contract_codegen', path: 'packages/contract_codegen', flutter: false),
  (name: 'adele_capabilities', path: 'packages/capabilities', flutter: false),
  (name: 'plugin_runtime', path: 'packages/plugin_runtime', flutter: false),
  (
    name: 'plugin_backend_host',
    path: 'packages/plugin_backend_host',
    flutter: false,
  ),
  (name: 'plugin_builder', path: 'packages/plugin_builder', flutter: false),
  (name: 'agent_kernel', path: 'packages/agent_kernel', flutter: false),
  (name: 'scripted_model', path: 'plugins/scripted_model', flutter: false),
  (
    name: 'scripted_model_contract',
    path: 'plugins/scripted_model/packages/contract',
    flutter: false,
  ),
  (
    name: 'scripted_model_backend',
    path: 'plugins/scripted_model/packages/backend',
    flutter: false,
  ),
  (name: 'workspace_demo', path: 'plugins/workspace_demo', flutter: false),
  (
    name: 'resource_inspector',
    path: 'plugins/resource_inspector',
    flutter: false,
  ),
  (
    name: 'resource_inspector_contract',
    path: 'plugins/resource_inspector/packages/contract',
    flutter: false,
  ),
  (
    name: 'resource_inspector_basic_backend',
    path: 'plugins/resource_inspector/packages/basic_backend',
    flutter: false,
  ),
  (
    name: 'resource_inspector_alternate_backend',
    path: 'plugins/resource_inspector/packages/alternate_backend',
    flutter: false,
  ),
  (
    name: 'resource_inspector_consumer',
    path: 'plugins/resource_inspector/packages/consumer',
    flutter: true,
  ),
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
      case 'generate':
        await _run('contract generation', 'dart', <String>[
          'run',
          'packages/contract_codegen/bin/contract_codegen.dart',
          if (arguments.skip(1).contains('--check')) '--check',
        ]);
        return;
      case 'analyze':
        await _run('repository tools', 'dart', <String>[
          'analyze',
          '--fatal-infos',
          'tools/adele.dart',
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
        await _run('adele_contract', 'dart', <String>[
          'test',
        ], workingDirectory: 'packages/contract');
        await _run('contract_codegen', 'dart', <String>[
          'test',
        ], workingDirectory: 'packages/contract_codegen');
        await _run('adele_plugin_api', 'dart', <String>[
          'test',
        ], workingDirectory: 'packages/plugin_api');
        await _run('adele_capabilities', 'dart', <String>[
          'test',
        ], workingDirectory: 'packages/capabilities');
        await _run('agent_kernel', 'dart', <String>[
          'test',
        ], workingDirectory: 'packages/agent_kernel');
        await _run('plugin_builder', 'dart', <String>[
          'test',
        ], workingDirectory: 'packages/plugin_builder');
        await _run('plugin_runtime', 'dart', <String>[
          'test',
          '--timeout',
          '10s',
        ], workingDirectory: 'packages/plugin_runtime');
        await _run(
          'plugin_backend_host',
          'dart',
          <String>['test'],
          workingDirectory: 'packages/plugin_backend_host',
        );
        await _run(
          'resource_inspector_contract',
          'dart',
          <String>['test', '--timeout', '4m'],
          workingDirectory: 'plugins/resource_inspector/packages/contract',
        );
        await _run(
          'scripted_model_contract',
          'dart',
          <String>['test', '--timeout', '4m'],
          workingDirectory: 'plugins/scripted_model/packages/contract',
        );
        await _run(
          'workspace_demo_contract',
          'dart',
          <String>['test'],
          workingDirectory: 'plugins/workspace_demo/packages/contract',
        );
        await _run(
          'workspace_demo_backend',
          'dart',
          <String>['test'],
          workingDirectory: 'plugins/workspace_demo/packages/backend',
        );
        await _run('adele_desktop', 'flutter', <String>[
          'test',
        ], workingDirectory: 'app');
        return;
      case 'check':
        await main(<String>['generate', '--check']);
        if (exitCode != 0) return;
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
        final String mode = _mode(arguments);
        await _run('adele_desktop', 'flutter', <String>[
          'run',
          '-d',
          device,
          '--$mode',
        ], workingDirectory: 'app');
        return;
      case 'build':
        final String target = arguments.length > 1
            ? arguments[1]
            : _defaultDesktopDevice();
        final String mode = _mode(arguments);
        await _run('adele_desktop $target build', 'flutter', <String>[
          'build',
          target,
          '--$mode',
        ], workingDirectory: 'app');
        return;
      case 'smoke':
        final String target = arguments.length > 1
            ? arguments[1]
            : _defaultDesktopDevice();
        if (target != 'linux') {
          throw UnsupportedError(
            'Development runtime smoke is currently implemented for Linux only.',
          );
        }
        final String mode = _mode(arguments) == 'debug'
            ? 'profile'
            : _mode(arguments);
        final List<String> defines = _developmentDefines();
        if (defines.isEmpty) {
          throw StateError(
            'Development smoke requires repository, plugin, and development directories.',
          );
        }
        await _run('adele_desktop $target $mode build', 'flutter', <String>[
          'build',
          target,
          '--$mode',
          '--target=lib/development_smoke.dart',
          ...defines,
        ], workingDirectory: 'app');
        await _run(
          'adele_desktop $target $mode runtime smoke',
          'app/build/linux/x64/$mode/bundle/adele_desktop',
          const <String>[],
        );
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

String _mode(List<String> arguments) {
  if (arguments.contains('--release')) return 'release';
  if (arguments.contains('--profile')) return 'profile';
  if (arguments.contains('--debug')) return 'debug';
  return 'debug';
}

List<String> _developmentDefines() {
  const List<String> names = <String>[
    'ADELE_DEVELOPMENT_REPOSITORY_ROOT',
    'ADELE_DEVELOPMENT_PLUGIN_DIRECTORY',
    'ADELE_DEVELOPMENT_DIRECTORY',
  ];
  final Map<String, String> environment = Platform.environment;
  if (!names.every(environment.containsKey)) return const <String>[];
  final String flutter = _which('flutter');
  final String dart = _which('dart');
  final ProcessResult machine = Process.runSync(flutter, <String>[
    '--version',
    '--machine',
  ]);
  if (machine.exitCode != 0) {
    throw StateError('Unable to inspect Flutter SDK: ${machine.stderr}');
  }
  final RegExpMatch? rootMatch = RegExp(
    r'"flutterRoot"\s*:\s*"([^"]+)"',
  ).firstMatch(machine.stdout.toString());
  if (rootMatch == null) throw StateError('Flutter SDK root was not reported.');
  final String flutterRoot = rootMatch.group(1)!;
  final String dartaotruntime =
      '$flutterRoot${Platform.pathSeparator}bin${Platform.pathSeparator}cache${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin${Platform.pathSeparator}dartaotruntime';
  return <String>[
    for (final String name in names) '--dart-define=$name=${environment[name]}',
    '--dart-define=ADELE_DEVELOPMENT_DART_EXECUTABLE=$dart',
    '--dart-define=ADELE_DEVELOPMENT_DARTAOTRUNTIME_EXECUTABLE=$dartaotruntime',
    '--dart-define=ADELE_DEVELOPMENT_FLUTTER_EXECUTABLE=$flutter',
  ];
}

String _which(String name) {
  final ProcessResult result = Process.runSync('which', <String>[name]);
  if (result.exitCode != 0) {
    throw StateError('Unable to resolve $name on PATH: ${result.stderr}');
  }
  return result.stdout.toString().trim();
}

void _usage() {
  stdout.writeln('''
Usage: dart tools/adele.dart <command>

Commands:
  bootstrap          Resolve the complete pub workspace.
  format [--check]   Format or verify formatting for all Dart files.
  generate [--check] Generate or verify committed contract transport files.
  analyze            Analyze every package and identify failures.
  test               Run public value tests and desktop widget tests.
  check              Verify formatting, analysis, and tests.
  run [device] [--debug|--profile|--release]
                     Run the desktop app in an explicit mode.
  build [target] [--debug|--profile|--release]
                     Build the desktop app in an explicit mode.
  smoke linux [--profile|--release]
                     Build and run the internal development runtime smoke path.
''');
}

final class _CommandFailure implements Exception {
  const _CommandFailure(this.label, this.exitCode);

  final String label;
  final int exitCode;
}
