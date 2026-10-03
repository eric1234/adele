import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

// test-plan must remain runnable before pub workspace bootstrap.
// ignore: avoid_relative_lib_imports
import '../packages/plugin_builder/lib/plugin_builder.dart';
import 'backend_artifacts.dart';
import 'code_editor_dependency.dart';
import 'code_editor_smoke.dart';
import 'contract_artifacts.dart';
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
    testConcurrency: 2,
    ciTestConcurrency: 4,
  ),
  TestTarget(
    name: 'adele_plugin_api',
    path: 'packages/plugin_api',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'adele_plugin_backend_support',
    path: 'packages/plugin_backend_support',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'adele_product',
    path: 'packages/product',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'adele_core_extensions',
    path: 'packages/core_extensions',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'adele_project_storage',
    path: 'packages/project_storage',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'adele_ui',
    path: 'packages/ui',
    executable: 'flutter',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'adele_orchestration',
    path: 'packages/orchestration',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'adele_environment',
    path: 'packages/environment',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'adele_model_tool',
    path: 'packages/model_tool',
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
    name: 'git_environment_backend',
    path: 'plugins/git_environment/packages/backend',
    executable: 'dart',
    arguments: <String>['test', '--timeout', '4m'],
    ciTestConcurrency: 1,
  ),
  TestTarget(
    name: 'filesystem_tools_plugin',
    path: 'plugins/filesystem_tools',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'filesystem_tools_backend',
    path: 'plugins/filesystem_tools/packages/backend',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'search_tools_plugin',
    path: 'plugins/search_tools',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'search_tools_backend',
    path: 'plugins/search_tools/packages/backend',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'command_tools_plugin',
    path: 'plugins/command_tools',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'command_tools_backend',
    path: 'plugins/command_tools/packages/backend',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'command_tools_contract',
    path: 'plugins/command_tools/packages/contract',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'agents_md_plugin',
    path: 'plugins/agents_md',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'agents_md_backend',
    path: 'plugins/agents_md/packages/backend',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'chat_strategy_contract',
    path: 'plugins/chat_strategy/packages/contract',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'chat_strategy_backend',
    path: 'plugins/chat_strategy/packages/backend',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'local_directory_project_backend',
    path: 'plugins/local_directory_project/packages/backend',
    executable: 'dart',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'local_directory_project_frontend',
    path: 'plugins/local_directory_project/packages/frontend',
    executable: 'flutter',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'task_browser_frontend',
    path: 'plugins/task_browser/packages/frontend',
    executable: 'flutter',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'terminal_frontend',
    path: 'plugins/terminal/packages/frontend',
    executable: 'flutter',
    arguments: <String>['test'],
  ),
  TestTarget(
    name: 'source_editor_frontend',
    path: 'plugins/source_editor/packages/frontend',
    executable: 'dart',
    arguments: <String>['test'],
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
    arguments: <String>['test', '--timeout', '4m'],
  ),
  TestTarget(
    name: 'openai_contract',
    path: 'plugins/openai/packages/contract',
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
    ciTestConcurrency: 1,
    linuxDesktopDeps: true,
  ),
];

const List<({String name, String path, bool flutter})>
analysisTargets = <({String name, String path, bool flutter})>[
  (name: 'adele_desktop', path: 'app', flutter: true),
  (name: 'adele_plugin_api', path: 'packages/plugin_api', flutter: false),
  (
    name: 'adele_plugin_backend_support',
    path: 'packages/plugin_backend_support',
    flutter: false,
  ),
  (name: 'adele_product', path: 'packages/product', flutter: false),
  (
    name: 'adele_project_storage',
    path: 'packages/project_storage',
    flutter: false,
  ),
  (
    name: 'adele_core_extensions',
    path: 'packages/core_extensions',
    flutter: false,
  ),
  (name: 'adele_ui', path: 'packages/ui', flutter: true),
  (name: 'adele_orchestration', path: 'packages/orchestration', flutter: false),
  (name: 'adele_environment', path: 'packages/environment', flutter: false),
  (name: 'adele_model_tool', path: 'packages/model_tool', flutter: false),
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
    name: 'openai_contract',
    path: 'plugins/openai/packages/contract',
    flutter: false,
  ),
  (
    name: 'openai_frontend',
    path: 'plugins/openai/packages/frontend',
    flutter: true,
  ),
  (name: 'git_environment', path: 'plugins/git_environment', flutter: false),
  (
    name: 'filesystem_tools_plugin',
    path: 'plugins/filesystem_tools',
    flutter: false,
  ),
  (name: 'search_tools_plugin', path: 'plugins/search_tools', flutter: false),
  (
    name: 'filesystem_tools_backend',
    path: 'plugins/filesystem_tools/packages/backend',
    flutter: false,
  ),
  (
    name: 'search_tools_backend',
    path: 'plugins/search_tools/packages/backend',
    flutter: false,
  ),
  (name: 'command_tools_plugin', path: 'plugins/command_tools', flutter: false),
  (
    name: 'command_tools_contract',
    path: 'plugins/command_tools/packages/contract',
    flutter: false,
  ),
  (
    name: 'command_tools_backend',
    path: 'plugins/command_tools/packages/backend',
    flutter: false,
  ),
  (
    name: 'filesystem_tools_frontend',
    path: 'plugins/filesystem_tools/packages/frontend',
    flutter: true,
  ),
  (
    name: 'command_tools_frontend',
    path: 'plugins/command_tools/packages/frontend',
    flutter: true,
  ),
  (name: 'agents_md_plugin', path: 'plugins/agents_md', flutter: false),
  (
    name: 'agents_md_backend',
    path: 'plugins/agents_md/packages/backend',
    flutter: false,
  ),
  (
    name: 'chat_strategy_contract',
    path: 'plugins/chat_strategy/packages/contract',
    flutter: false,
  ),
  (
    name: 'chat_strategy_backend',
    path: 'plugins/chat_strategy/packages/backend',
    flutter: false,
  ),
  (
    name: 'chat_strategy_frontend',
    path: 'plugins/chat_strategy/packages/frontend',
    flutter: true,
  ),
  (
    name: 'local_directory_project_backend',
    path: 'plugins/local_directory_project/packages/backend',
    flutter: false,
  ),
  (
    name: 'local_directory_project_frontend',
    path: 'plugins/local_directory_project/packages/frontend',
    flutter: true,
  ),
  (
    name: 'task_browser_frontend',
    path: 'plugins/task_browser/packages/frontend',
    flutter: true,
  ),
  (
    name: 'terminal_frontend',
    path: 'plugins/terminal/packages/frontend',
    flutter: true,
  ),
  (
    name: 'source_editor_frontend',
    path: 'plugins/source_editor/packages/frontend',
    flutter: true,
  ),
  (
    name: 'git_environment_backend',
    path: 'plugins/git_environment/packages/backend',
    flutter: false,
  ),
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
      case 'help':
      case '--help':
        _usage();
        return;
      case 'prepare-code-editor':
        var reprepare = false;
        File? archive;
        for (var index = 1; index < arguments.length; index++) {
          final option = arguments[index];
          if (option == '--reprepare' && !reprepare) {
            reprepare = true;
          } else if (option == '--archive' &&
              archive == null &&
              index + 1 < arguments.length &&
              !arguments[index + 1].startsWith('--')) {
            archive = File(arguments[++index]);
          } else {
            throw const TestUsageException(
              'prepare-code-editor takes only [--reprepare] [--archive FILE].',
            );
          }
        }
        await prepareCodeEditorSource(
          Directory.current,
          archive: archive,
          reprepare: reprepare,
        );
        return;
      case 'build-code-editor-tests':
        if (arguments.length != 1) {
          throw const TestUsageException(
            'build-code-editor-tests takes no options.',
          );
        }
        stdout.writeln(
          (await buildNativeCodeEditorForTests(Directory.current)).path,
        );
        return;
      case 'editor-smoke':
        if (arguments.length < 2 ||
            arguments.length > 4 ||
            arguments[1] != 'linux' ||
            arguments.skip(2).toSet().length != arguments.length - 2 ||
            arguments
                .skip(2)
                .any(
                  (option) =>
                      option != '--prepare-only' && option != '--workspace',
                )) {
          throw const TestUsageException(
            'editor-smoke requires linux [--workspace] [--prepare-only].',
          );
        }
        await runCodeEditorSmoke(
          Directory.current,
          prepareOnly: arguments.contains('--prepare-only'),
          workspace: arguments.contains('--workspace'),
        );
        return;
      case 'bootstrap':
        if (arguments.length != 1) {
          throw const TestUsageException('bootstrap takes no options.');
        }
        await withCodeEditorSource(Directory.current, (_) async {
          await _run('workspace dependency resolution', 'flutter', <String>[
            'pub',
            'get',
          ]);
          await _run('workspace package listing', 'dart', <String>[
            'pub',
            'workspace',
            'list',
          ]);
          await runContractCodegen(repositoryRoot: Directory.current);
        });
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
        await runContractCodegen(
          repositoryRoot: Directory.current,
          options: <String>[
            if (arguments.skip(1).contains('--check')) '--check',
          ],
        );
        return;
      case 'clean-contracts':
        if (arguments.length != 1) {
          throw const TestUsageException('clean-contracts takes no options.');
        }
        await runContractCodegen(
          repositoryRoot: Directory.current,
          options: const <String>['--clean'],
        );
        return;
      case 'analyze':
        if (arguments.length != 1) {
          throw const TestUsageException('analyze takes no options.');
        }
        await withCodeEditorSource(Directory.current, (_) async {
          await runContractCodegen(repositoryRoot: Directory.current);
          await _run('repository tools', 'dart', <String>[
            'analyze',
            '--fatal-infos',
            'tools',
          ]);
          await _run('repository tool tests', 'dart', <String>[
            'analyze',
            '--fatal-infos',
            'test/tools',
          ]);
          for (final package in analysisTargets) {
            await _run(
              package.name,
              package.flutter ? 'flutter' : 'dart',
              <String>['analyze', '--fatal-infos'],
              workingDirectory: package.path,
            );
          }
        });
        return;
      case 'test':
        exitCode = await _runTests(
          parseTestOptions(arguments.skip(1).toList(growable: false)),
        );
        return;
      case 'test-plan':
        if (arguments.length != 2 || arguments[1] != '--json') {
          throw const TestUsageException('test-plan requires exactly --json.');
        }
        stdout.writeln(testPlanJson());
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
      case 'build':
        _validateDesktopArguments(arguments);
        final String target = arguments.length > 1
            ? arguments[1]
            : _defaultDesktopDevice();
        final String mode = _mode(arguments);
        await withCodeEditorSource(Directory.current, (_) async {
          final String flutter = target == 'linux'
              ? _which('flutter')
              : 'flutter';
          if (target != 'linux') {
            await runContractCodegen(repositoryRoot: Directory.current);
          }
          final List<String> defines = target == 'linux'
              ? await prepareDesktopPluginDefines(
                  repositoryRoot: Directory.current,
                  flutterExecutable: flutter,
                )
              : const <String>[];
          await _run(
            'adele_desktop $target ${arguments.first}',
            flutter,
            <String>[
              arguments.first,
              if (arguments.first == 'run') '-d',
              target,
              '--$mode',
              ...defines,
            ],
            workingDirectory: 'app',
            environment: {'RUST_MIN_STACK': '16777216'},
          );
        });
        return;
      case 'smoke':
        _validateDesktopArguments(arguments);
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
        await withCodeEditorSource(Directory.current, (_) async {
          await runContractCodegen(repositoryRoot: Directory.current);
          await _run(
            'adele_desktop $target $mode build',
            'flutter',
            <String>[
              'build',
              target,
              '--$mode',
              '--target=tool/development_runtime_smoke/main.dart',
              ...defines,
            ],
            workingDirectory: 'app',
            environment: {'RUST_MIN_STACK': '16777216'},
          );
          await _run(
            'adele_desktop $target $mode runtime smoke',
            'app/build/linux/x64/$mode/bundle/adele_desktop',
            const <String>[],
          );
        });
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
  } on PluginBuildFailure catch (failure) {
    stderr.writeln('FAILED: $failure');
    final int? compilerExitCode = failure.diagnostic?.exitCode;
    exitCode = compilerExitCode != null && compilerExitCode != 0
        ? compilerExitCode
        : 1;
  } on StateError catch (failure) {
    stderr.writeln('FAILED: ${failure.message}');
    exitCode = 1;
  }
}

int defaultTestJobs([int? numberOfProcessors]) {
  return math.min(
    _maximumDefaultTestJobs,
    math.max(1, numberOfProcessors ?? Platform.numberOfProcessors),
  );
}

int parseTestJobs(List<String> arguments, {int? numberOfProcessors}) {
  return parseTestOptions(
    arguments,
    numberOfProcessors: numberOfProcessors,
  ).jobs;
}

final class TestOptions {
  const TestOptions({required this.jobs, required this.ci, this.target});

  final bool ci;
  final int jobs;
  final String? target;
}

TestOptions parseTestOptions(
  List<String> arguments, {
  int? numberOfProcessors,
}) {
  int? jobs;
  String? target;
  bool ci = false;
  for (int index = 0; index < arguments.length; index++) {
    final String argument = arguments[index];
    if (argument == '--jobs' || argument.startsWith('--jobs=')) {
      if (jobs != null) {
        throw const TestUsageException('--jobs may only be specified once.');
      }
      if (argument == '--jobs' && index + 1 >= arguments.length) {
        throw const TestUsageException('--jobs requires a positive integer.');
      }
      final String value = argument == '--jobs'
          ? arguments[++index]
          : argument.substring('--jobs='.length);
      jobs = _parseTestJobsValue(value);
    } else if (argument == '--target' || argument.startsWith('--target=')) {
      if (argument == '--target' && index + 1 >= arguments.length) {
        throw const TestUsageException('--target requires a target name.');
      }
      if (target != null) {
        throw const TestUsageException('--target may only be specified once.');
      }
      final String value = argument == '--target'
          ? arguments[++index]
          : argument.substring('--target='.length);
      if (value.isEmpty || value.startsWith('-')) {
        throw const TestUsageException('--target requires a target name.');
      }
      target = value;
    } else if (argument == '--ci') {
      if (ci) {
        throw const TestUsageException('--ci may only be specified once.');
      }
      ci = true;
    } else {
      throw TestUsageException('Unknown test option: $argument');
    }
  }
  if (jobs != null && target != null) {
    throw const TestUsageException('--target and --jobs cannot be combined.');
  }
  if (ci && target == null) {
    throw const TestUsageException('--ci requires --target.');
  }
  return TestOptions(
    jobs: jobs ?? (target == null ? defaultTestJobs(numberOfProcessors) : 1),
    ci: ci,
    target: target,
  );
}

int _parseTestJobsValue(String value) {
  final int? jobs = RegExp(r'^[1-9][0-9]*$').hasMatch(value)
      ? int.tryParse(value)
      : null;
  if (jobs == null) {
    throw TestUsageException(
      'Invalid --jobs value "$value"; expected a positive integer.',
    );
  }
  return jobs;
}

TestTarget lookupTestTarget(
  String name, [
  List<TestTarget> targets = testTargets,
]) {
  for (final TestTarget target in targets) {
    if (target.name == name) return target;
  }
  throw TestUsageException('Unknown test target: $name');
}

String testPlanJson([List<TestTarget> targets = testTargets]) {
  return jsonEncode(<String, Object>{
    'include': <Map<String, Object?>>[
      for (final TestTarget target in targets)
        <String, Object?>{
          'name': target.name,
          'linuxDesktopDeps': target.linuxDesktopDeps,
          'ciTestConcurrency': target.ciTestConcurrency,
        },
    ],
  });
}

Future<int> _runTests(TestOptions options) async {
  final List<TestTarget> targets = options.target == null
      ? testTargets
      : <TestTarget>[lookupTestTarget(options.target!)];
  await prepareCodeEditorSource(Directory.current);
  await runContractCodegen(repositoryRoot: Directory.current);
  final Directory? codeEditorLibrary =
      targets.any((target) => target.name == 'adele_desktop')
      ? await buildNativeCodeEditorForTests(Directory.current)
      : null;
  return withCodeEditorSource(Directory.current, (source) async {
    if (codeEditorLibrary != null) {
      final prepared =
          jsonDecode(
                await File(
                  '${source.path}/.adele-preparation.json',
                ).readAsString(),
              )
              as Map;
      if (codeEditorLibrary.parent.parent.uri.pathSegments
              .where((part) => part.isNotEmpty)
              .last !=
          prepared['identity']) {
        throw StateError(
          'Native editor inputs changed between compilation and test admission.',
        );
      }
    }
    stdout.writeln(
      'Running ${targets.length} test targets with up to ${options.jobs} jobs.',
    );
    final TestRunSummary summary = await runTestTargets(
      targets: targets,
      jobs: options.jobs,
      execute: (TestTarget target) async {
        final Process process = await Process.start(
          target.executable,
          target.argumentsFor(ci: options.ci),
          mode: ProcessStartMode.inheritStdio,
          runInShell: Platform.isWindows,
          workingDirectory: target.path,
          environment: target.name == 'adele_desktop'
              ? {
                  'FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR':
                      codeEditorLibrary!.path,
                }
              : null,
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
  });
}

Future<void> _run(
  String label,
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  stdout.writeln('==> $label');
  final Process process = await Process.start(
    executable,
    arguments,
    mode: ProcessStartMode.inheritStdio,
    runInShell: Platform.isWindows,
    workingDirectory: workingDirectory,
    environment: environment,
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

void _validateDesktopArguments(List<String> arguments) {
  if (arguments.length > 3 ||
      (arguments.length > 1 &&
          !const ['linux', 'macos', 'windows'].contains(arguments[1])) ||
      (arguments.length > 2 &&
          !const [
            '--debug',
            '--profile',
            '--release',
          ].contains(arguments[2]))) {
    throw const TestUsageException(
      'Expected [linux|macos|windows] [--debug|--profile|--release].',
    );
  }
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
  bootstrap          Prepare CodeForge source, resolve pub, and generate contracts.
  prepare-code-editor [--reprepare] [--archive FILE]
                     Verify or prepare pinned source without invoking Rust or pub.
                     --reprepare explicitly replaces source under its exclusive lease.
  build-code-editor-tests
                     Build locked native test library and print its directory.
  format [--check]   Format or verify formatting for all Dart files.
  generate [--check] Materialize or verify local native contract transport.
  clean-contracts    Remove ADELE native contract outputs, including marked orphans.
  analyze            Analyze every package and identify failures.
  test [--jobs N]    Run tests with at most N package processes (default: up to 2).
  test --target NAME [--ci]
                      Run exactly one named test target; --ci applies CI policy.
                      --target=NAME is also supported.
  test-plan --json   Print the CI test matrix without resolving dependencies.
  check              Verify formatting, analysis, and tests.
  run [device] [--debug|--profile|--release]
                     Run the desktop app in an explicit mode.
  build [target] [--debug|--profile|--release]
                     Build the desktop app in an explicit mode.
  smoke linux [--profile|--release]
                     Build and run the internal development runtime smoke path.
  editor-smoke linux [--workspace] [--prepare-only]
                     Package editor smoke; optionally include the real app workspace or skip execution.
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
