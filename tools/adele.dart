import 'dart:io';
import 'dart:math' as math;

import 'test_runner.dart';

const int _maximumDefaultTestJobs = 2;

const List<TestTarget> testTargets = <TestTarget>[
  TestTarget(
    name: 'adele_tools',
    path: '.',
    executable: 'dart',
    arguments: <String>['test', 'test/tools'],
  ),
  TestTarget(
    name: 'adele_contract',
    path: 'packages/contract',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'contract_codegen',
    path: 'packages/contract_codegen',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'adele_plugin_api',
    path: 'packages/plugin_api',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'adele_model_provider',
    path: 'packages/model_provider',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'adele_capabilities',
    path: 'packages/capabilities',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'agent_kernel',
    path: 'packages/agent_kernel',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'plugin_builder',
    path: 'packages/plugin_builder',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'plugin_runtime',
    path: 'packages/plugin_runtime',
    executable: 'dart',
    arguments: <String>['test', '--timeout', '10s'],
  ),
  TestTarget(
    name: 'plugin_backend_host',
    path: 'packages/plugin_backend_host',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'resource_inspector_contract',
    path: 'plugins/resource_inspector/packages/contract',
    executable: 'dart',
    arguments: <String>['test', '--timeout', '4m'],
  ),
  TestTarget(
    name: 'scripted_model_contract',
    path: 'plugins/scripted_model/packages/contract',
    executable: 'dart',
    arguments: <String>['test', '--timeout', '4m'],
  ),
  TestTarget(
    name: 'scripted_model_backend',
    path: 'plugins/scripted_model/packages/backend',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'openai_model_provider_backend',
    path: 'plugins/openai/packages/backend',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'workspace_demo_contract',
    path: 'plugins/workspace_demo/packages/contract',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'workspace_demo_backend',
    path: 'plugins/workspace_demo/packages/backend',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'adele_desktop',
    path: 'app',
    executable: 'flutter',
    arguments: <String>['test'],
  ),
];

const List<({String name, String path, bool flutter})>
_packages = <({String name, String path, bool flutter})>[
  (name: 'adele_desktop', path: 'app', flutter: true),
  (name: 'adele_plugin_api', path: 'packages/plugin_api', flutter: false),
  (name: 'adele_contract', path: 'packages/contract', flutter: false),
  (
    name: 'adele_model_provider',
    path: 'packages/model_provider',
    flutter: false,
  ),
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
  (name: 'openai_plugin', path: 'plugins/openai', flutter: false),
  (
    name: 'openai_model_provider_backend',
    path: 'plugins/openai/packages/backend',
    flutter: false,
  ),
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
          'tools',
          'test/tools',
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
        exitCode = await _runTests(
          parseTestJobs(arguments.skip(1).toList(growable: false)),
        );
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
  } on TestUsageException catch (failure) {
    stderr.writeln('ERROR: ${failure.message}');
    _usage();
    exitCode = 64;
  } on _CommandFailure catch (failure) {
    stderr.writeln(
      'FAILED: ${failure.label} exited with code ${failure.exitCode}.',
    );
    exitCode = failure.exitCode;
  }
}

int defaultTestJobs([int? numberOfProcessors]) {
  return math.min(
    _maximumDefaultTestJobs,
    math.max(1, numberOfProcessors ?? Platform.numberOfProcessors),
  );
}

int parseTestJobs(List<String> arguments, {int? numberOfProcessors}) {
  int? jobs;
  for (int index = 0; index < arguments.length; index++) {
    final String argument = arguments[index];
    String? value;
    if (argument == '--jobs') {
      if (index + 1 >= arguments.length) {
        throw const TestUsageException('--jobs requires a positive integer.');
      }
      value = arguments[++index];
    } else if (argument.startsWith('--jobs=')) {
      value = argument.substring('--jobs='.length);
    } else {
      throw TestUsageException('Unknown test option: $argument');
    }
    if (jobs != null) {
      throw const TestUsageException('--jobs may only be specified once.');
    }
    if (!RegExp(r'^[1-9][0-9]*$').hasMatch(value)) {
      throw TestUsageException(
        'Invalid --jobs value "$value"; expected a positive integer.',
      );
    }
    jobs = int.tryParse(value);
    if (jobs == null) {
      throw TestUsageException(
        'Invalid --jobs value "$value"; expected a positive integer.',
      );
    }
  }
  return jobs ?? defaultTestJobs(numberOfProcessors);
}

Future<int> _runTests(int jobs) async {
  stdout.writeln(
    'Running ${testTargets.length} test targets with up to $jobs jobs.',
  );
  final TestRunSummary summary = await runTestTargets(
    targets: testTargets,
    jobs: jobs,
    execute: (TestTarget target) async {
      final Process process = await Process.start(
        target.executable,
        target.arguments,
        mode: ProcessStartMode.inheritStdio,
        runInShell: Platform.isWindows,
        workingDirectory: target.path,
      );
      return process.exitCode;
    },
    onStart: (TestTarget target) {
      stdout.writeln('==> START test: ${target.name}');
    },
    onComplete: (TestTargetResult result) {
      final String elapsed = formatTestDuration(result.elapsed);
      if (result.passed) {
        stdout.writeln('==> PASS test: ${result.target.name} ($elapsed)');
      } else {
        stdout.writeln(
          '==> FAIL test: ${result.target.name} '
          '($elapsed, exit ${result.exitCode})',
        );
        if (result.error case final Object error) stderr.writeln(error);
      }
    },
  );

  if (summary.failures.isNotEmpty) {
    stderr.writeln('FAILED TEST TARGETS:');
    for (final TestTargetResult failure in summary.failures) {
      stderr.writeln('  ${failure.target.name} (exit ${failure.exitCode})');
    }
  }
  stdout.writeln(
    'TEST SUMMARY: total ${summary.results.length}, passed ${summary.passed}, '
    'failed ${summary.failures.length}, '
    'elapsed ${formatTestDuration(summary.elapsed)}',
  );
  return summary.succeeded ? 0 : summary.failures.first.exitCode;
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
  test [--jobs N]    Run tests with at most N package processes (default: up to 2).
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

final class TestUsageException implements Exception {
  const TestUsageException(this.message);

  final String message;
}
