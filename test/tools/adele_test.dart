import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../../tools/adele.dart';
import '../../tools/stock_frontend_descriptors.dart';
import '../../tools/test_runner.dart';

void main() {
  test(
    'editor-smoke wires workspace and preparation as independent opt-ins',
    () {
      final source = File('tools/adele.dart').readAsStringSync();
      final start = source.indexOf("case 'editor-smoke':");
      final route = source.substring(
        start,
        source.indexOf("case 'bootstrap':", start),
      );
      expect(
        route,
        contains("prepareOnly: arguments.contains('--prepare-only')"),
      );
      expect(route, contains("workspace: arguments.contains('--workspace')"));
      expect(route, contains('arguments.skip(2).toSet().length'));
      expect(route, contains('linux [--workspace] [--prepare-only]'));
    },
  );

  test(
    'editor-smoke rejects unsupported and duplicate options before preparation',
    () async {
      for (final options in [
        <String>[],
        ['windows', '--workspace'],
        ['linux', '--workspace', '--workspace'],
        ['linux', '--prepare-only', '--prepare-only'],
        ['linux', '--other'],
      ]) {
        final result = await Process.run(Platform.resolvedExecutable, [
          'tools/adele.dart',
          'editor-smoke',
          ...options,
        ]);
        expect(result.exitCode, 64, reason: options.toString());
        expect(result.stderr, contains('linux [--workspace] [--prepare-only]'));
      }
    },
  );

  group('test target pool', () {
    test(
      'bounds concurrency, overlaps work, and executes every target',
      () async {
        final List<TestTarget> targets = _targets(5);
        final List<Completer<void>> releases = <Completer<void>>[
          for (int index = 0; index < targets.length; index++)
            Completer<void>(),
        ];
        final List<String> started = <String>[];
        int active = 0;
        int maximumActive = 0;

        final Future<TestRunSummary> pending = runTestTargets(
          targets: targets,
          jobs: 2,
          execute: (TestTarget target) async {
            active++;
            maximumActive = active > maximumActive ? active : maximumActive;
            started.add(target.name);
            await releases[int.parse(target.name)].future;
            active--;
            return 0;
          },
        );

        await _until(() => started.length == 2);
        expect(maximumActive, 2);
        expect(started, <String>['0', '1']);
        releases[0].complete();
        await _until(() => started.length == 3);
        expect(active, 2);
        for (final Completer<void> release in releases) {
          if (!release.isCompleted) release.complete();
        }

        final TestRunSummary summary = await pending;
        expect(started, <String>['0', '1', '2', '3', '4']);
        expect(summary.succeeded, isTrue);
        expect(summary.results, hasLength(5));
        expect(maximumActive, 2);
      },
    );

    test('continues queued targets and fails after one target fails', () async {
      final List<String> executed = <String>[];
      final TestRunSummary summary = await runTestTargets(
        targets: _targets(4),
        jobs: 2,
        execute: (TestTarget target) async {
          executed.add(target.name);
          return target.name == '1' ? 7 : 0;
        },
      );

      expect(executed, containsAll(<String>['0', '1', '2', '3']));
      expect(summary.succeeded, isFalse);
      expect(summary.passed, 3);
      expect(summary.failures.single.target.name, '1');
      expect(summary.failures.single.exitCode, 7);
    });

    test('records executor exceptions and continues', () async {
      final List<String> executed = <String>[];
      final TestRunSummary summary = await runTestTargets(
        targets: _targets(3),
        jobs: 1,
        execute: (TestTarget target) async {
          executed.add(target.name);
          if (target.name == '0') throw StateError('start failed');
          return 0;
        },
      );

      expect(executed, <String>['0', '1', '2']);
      expect(summary.failures.single.exitCode, 1);
      expect(summary.failures.single.error, isA<StateError>());
    });
  });

  group('--jobs', () {
    test('uses a processor-bounded default', () {
      expect(parseTestJobs(const <String>[], numberOfProcessors: 2), 2);
      expect(parseTestJobs(const <String>[], numberOfProcessors: 32), 2);
      expect(parseTestJobs(const <String>[], numberOfProcessors: 0), 1);
    });

    test('accepts separated and equals forms', () {
      expect(parseTestJobs(<String>['--jobs', '3']), 3);
      expect(parseTestJobs(<String>['--jobs=5']), 5);
    });

    test(
      'rejects missing, zero, negative, malformed, and duplicate values',
      () {
        for (final List<String> arguments in <List<String>>[
          <String>['--jobs'],
          <String>['--jobs', '0'],
          <String>['--jobs', '-1'],
          <String>['--jobs', 'two'],
          <String>['--jobs', '2', '--jobs=3'],
        ]) {
          expect(
            () => parseTestJobs(arguments),
            throwsA(isA<TestUsageException>()),
            reason: arguments.toString(),
          );
        }
      },
    );
  });

  group('test options', () {
    test('target forms produce equivalent options and maintained targets', () {
      for (final target in testTargets) {
        for (final ci in [false, true]) {
          final separated = parseTestOptions([
            '--target',
            target.name,
            if (ci) '--ci',
          ]);
          final equals = parseTestOptions([
            '--target=${target.name}',
            if (ci) '--ci',
          ]);
          expect(separated.target, target.name);
          expect(separated.jobs, 1);
          expect(separated.ci, ci);
          expect(equals.target, separated.target);
          expect(equals.jobs, separated.jobs);
          expect(equals.ci, separated.ci);
          expect(lookupTestTarget(separated.target!), same(target));
          expect(lookupTestTarget(equals.target!), same(target));
        }
      }
      expect(parseTestOptions(['--ci', '--target=adele_tools']).ci, isTrue);
    });

    final invalidOptions = <List<String>>[
      ['--target'],
      ['--target', ''],
      ['--target='],
      ['--target', '--ci'],
      ['--target=--ci'],
      ['--target', 'one', '--target', 'two'],
      ['--target=one', '--target=two'],
      ['--target', 'one', '--target=two'],
      ['--target=one', '--target', 'two'],
      ['--ci'],
      ['--target', 'one', '--ci', '--ci'],
      ['--target=one', '--ci', '--ci'],
      ['--other'],
      for (final target in [
        ['--target', 'adele_tools'],
        ['--target=adele_tools'],
      ])
        for (final jobs in [
          ['--jobs', '2'],
          ['--jobs=2'],
        ]) ...[
          [...target, ...jobs],
          [...jobs, ...target],
        ],
    ];

    test('rejects missing, empty, duplicate, and conflicting options', () {
      for (final arguments in invalidOptions) {
        expect(
          () => parseTestOptions(arguments),
          throwsA(isA<TestUsageException>()),
          reason: arguments.toString(),
        );
      }
    });

    test('unknown names use normal target validation for both forms', () {
      for (final arguments in [
        ['--target', 'missing'],
        ['--target=missing'],
      ]) {
        final options = parseTestOptions(arguments);
        expect(options.target, 'missing');
        expect(
          () => lookupTestTarget(options.target!),
          throwsA(
            isA<TestUsageException>().having(
              (error) => error.message,
              'message',
              'Unknown test target: missing',
            ),
          ),
        );
      }
    });

    for (final arguments in [
      ...invalidOptions,
      ['--target', 'missing'],
      ['--target=missing', '--ci'],
    ]) {
      test('CLI rejects $arguments before preparation or execution', () async {
        final script = File('tools/adele.dart').absolute.path;
        final directory = Directory.systemTemp.createTempSync(
          'adele-test-options-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final result = await Process.run(Platform.resolvedExecutable, [
          script,
          'test',
          ...arguments,
        ], workingDirectory: directory.path);
        expect(result.exitCode, 64, reason: arguments.toString());
        expect(result.stderr, startsWith('ERROR: '));
        expect(result.stdout, startsWith('Usage: dart tools/adele.dart'));
        expect(result.stdout, contains('--target=NAME'));
        expect(result.stdout, isNot(contains('==>')));
        expect(directory.listSync(), isEmpty);
      });
    }
  });

  group('test plan', () {
    test(
      'catalog and checkout preparation are included in maintained targets',
      () {
        final runtime = lookupTestTarget('plugin_runtime');
        expect(runtime.path, 'packages/plugin_runtime');
        expect(runtime.executable, 'dart');
        expect(runtime.argumentsFor(), ['test', '--timeout', '10s']);
        expect(
          File(
            '${runtime.path}/test/prepared_plugin_catalog_test.dart',
          ).existsSync(),
          isTrue,
        );
        final tools = lookupTestTarget('adele_tools');
        expect(tools.path, '.');
        expect(tools.argumentsFor(), ['test', 'test/tools']);
        expect(
          File('test/tools/backend_artifacts_test.dart').existsSync(),
          isTrue,
        );
        final plan = jsonDecode(testPlanJson()) as Map<String, Object?>;
        expect(
          (plan['include']! as List<Object?>).cast<Map<String, Object?>>().map(
            (entry) => entry['name'],
          ),
          containsAll(['plugin_runtime', 'adele_tools']),
        );
      },
    );

    test('contains every unique target exactly once with setup metadata', () {
      final Map<String, Object?> plan =
          jsonDecode(testPlanJson())! as Map<String, Object?>;
      final List<Object?> include = plan['include']! as List<Object?>;
      final Iterable<Map<String, Object?>> entries = include.cast();
      final List<String> names = <String>[
        for (final Map<String, Object?> item in entries)
          item['name']! as String,
      ];

      expect(include, hasLength(testTargets.length));
      expect(names, <String>[
        for (final TestTarget target in testTargets) target.name,
      ]);
      expect(names.toSet(), hasLength(testTargets.length));
      expect(
        testTargets
            .where((target) => target.nativeCodeEditor)
            .map((target) => target.name),
        ['source_editor_frontend', 'adele_desktop'],
      );
      for (final entry in entries) {
        expect(
          entry['nativeCodeEditor'],
          ['source_editor_frontend', 'adele_desktop'].contains(entry['name']),
        );
      }
      expect(
        include,
        everyElement(
          isA<Map<String, Object?>>().having(
            (Map<String, Object?> item) => item.keys,
            'keys',
            unorderedEquals(<String>[
              'name',
              'linuxDesktopDeps',
              'nativeCodeEditor',
              'ciTestConcurrency',
            ]),
          ),
        ),
      );
      expect(
        <String>[
          for (final TestTarget target in testTargets)
            if (target.linuxDesktopDeps) target.name,
        ],
        <String>['adele_desktop'],
      );
      expect(
        <String, Object?>{
          for (final Map<String, Object?> item in entries)
            item['name']! as String: item['ciTestConcurrency'],
        },
        <String, Object?>{
          for (final TestTarget target in testTargets)
            target.name: switch (target.name) {
              'contract_codegen' => 4,
              'git_environment_backend' || 'adele_desktop' => 1,
              _ => null,
            },
        },
      );
    });
  });

  group('target lookup', () {
    test(
      'desktop CI serializes compiler-heavy fixtures without changing local defaults',
      () {
        final target = lookupTestTarget('adele_desktop');
        expect(target.nativeCodeEditor, isTrue);
        expect(target.argumentsFor(), ['test']);
        expect(target.argumentsFor(ci: true), ['test', '--concurrency', '1']);
        expect(target.ciTestConcurrency, 1);
      },
    );

    test('returns the exact target', () {
      expect(lookupTestTarget('contract_codegen').name, 'contract_codegen');
    });

    test(
      'discovers Chat backend as a pure-Dart target with default CI policy',
      () {
        final TestOptions options = parseTestOptions(<String>[
          '--target',
          'chat_strategy_backend',
          '--ci',
        ]);
        final TestTarget target = lookupTestTarget(options.target!);

        expect(target.path, 'plugins/chat_strategy/packages/backend');
        expect(target.executable, 'dart');
        expect(target.argumentsFor(ci: options.ci), <String>['test']);
        expect(target.linuxDesktopDeps, isFalse);
        expect(target.ciTestConcurrency, isNull);
      },
    );

    test(
      'Chat components are discovered and production stays Chat-independent',
      () {
        expect(
          File('plugins/chat_strategy/pubspec.yaml').existsSync(),
          isFalse,
        );
        for (final component in ['contract', 'backend']) {
          final path = 'plugins/chat_strategy/packages/$component';
          final name = 'chat_strategy_$component';
          expect(lookupTestTarget(name).path, path);
          expect(
            analysisTargets.singleWhere((target) => target.name == name).path,
            path,
          );
          expect(
            File('pubspec.yaml').readAsStringSync(),
            contains('  - $path\n'),
          );
        }
        final forbidden = RegExp(
          r'ChatController|StockChatFrontend|'
          r'StockChatExecutionStatus|stock-chat-controller-v1|chatStrategyId|'
          r'ChatStrategyPlugin|ChatSessionStore',
        );
        for (final file in Directory('app/lib').listSync(recursive: true)) {
          if (file is! File || !file.path.endsWith('.dart')) continue;
          expect(
            forbidden.hasMatch(file.readAsStringSync()),
            isFalse,
            reason:
                'Production host must remain Chat-independent: ${file.path}',
          );
        }
      },
    );

    test('discovers the opt-in evaluator without stock startup or Flutter', () {
      const root = 'plugins/session_evaluator/packages';
      for (final component in ['contract', 'backend']) {
        final name = 'session_evaluator_$component';
        final path = '$root/$component';
        final target = lookupTestTarget(name);
        expect(target.path, path);
        expect(target.executable, 'dart');
        expect(target.argumentsFor(ci: true), ['test']);
        expect(target.linuxDesktopDeps, isFalse);
        expect(target.nativeCodeEditor, isFalse);
        final analysis = analysisTargets.singleWhere(
          (target) => target.name == name,
        );
        expect(analysis.path, path);
        expect(analysis.flutter, isFalse);
        expect(
          File('pubspec.yaml').readAsStringSync(),
          contains('  - $path\n'),
        );
        final manifest =
            loadYaml(File('$path/pubspec.yaml').readAsStringSync()) as YamlMap;
        expect(manifest['resolution'], 'workspace');
        final dependencies = manifest['dependencies'] as YamlMap;
        for (final forbidden in [
          'flutter',
          'adele_desktop',
          'agent_kernel',
          'plugin_runtime',
          'plugin_backend_host',
          'sqlite3',
        ]) {
          expect(dependencies.containsKey(forbidden), isFalse, reason: path);
        }
      }
      const source = '$root/contract/lib/session_evaluator_contract';
      expect(
        File('contract_codegen.yaml').readAsStringSync(),
        contains('  - $source.dart\n'),
      );
      expect(
        File('.gitignore').readAsStringSync(),
        contains('/$source.g.dart\n'),
      );
      expect(
        File('tools/backend_artifacts.dart').readAsStringSync(),
        isNot(contains('session_evaluator')),
      );
      expect(Directory('$root/frontend').existsSync(), isFalse);
      final app =
          loadYaml(File('app/pubspec.yaml').readAsStringSync()) as YamlMap;
      for (final name in [
        'session_evaluator_contract',
        'session_evaluator_backend',
      ]) {
        expect((app['dependencies'] as YamlMap).containsKey(name), isFalse);
      }
      expect(
        (app['dev_dependencies'] as YamlMap).containsKey(
          'session_evaluator_contract',
        ),
        isTrue,
      );
    });

    test(
      'discovers AGENTS.md as a pure-Dart target with default CI policy',
      () {
        final TestOptions options = parseTestOptions(<String>[
          '--target',
          'agents_md_plugin',
          '--ci',
        ]);
        final TestTarget target = lookupTestTarget(options.target!);

        expect(target.path, 'plugins/agents_md');
        expect(target.executable, 'dart');
        expect(target.argumentsFor(ci: options.ci), <String>['test']);
        expect(target.linuxDesktopDeps, isFalse);
        expect(target.ciTestConcurrency, isNull);
      },
    );

    test('discovers core extensions with the pure-Dart runner policy', () {
      final TestOptions options = parseTestOptions(<String>[
        '--target',
        'adele_core_extensions',
        '--ci',
      ]);
      final TestTarget target = lookupTestTarget(options.target!);

      expect(target.path, 'packages/core_extensions');
      expect(target.executable, 'dart');
      expect(target.argumentsFor(), <String>['test']);
      expect(target.argumentsFor(ci: options.ci), <String>['test']);
      expect(target.linuxDesktopDeps, isFalse);
      expect(target.ciTestConcurrency, isNull);
    });

    test(
      'discovers the public Project storage contract in workspace and CI',
      () {
        const name = 'adele_project_storage';
        const path = 'packages/project_storage';
        final target = lookupTestTarget(name);
        expect(target.path, path);
        expect(target.executable, 'dart');
        expect(target.argumentsFor(ci: true), ['test']);
        expect(target.linuxDesktopDeps, isFalse);
        final analysis = analysisTargets.singleWhere(
          (value) => value.name == name,
        );
        expect(analysis.path, path);
        expect(analysis.flutter, isFalse);
        expect(
          File('pubspec.yaml').readAsStringSync(),
          contains('  - $path\n'),
        );
      },
    );

    test('discovers remote extension support and stock backend targets', () {
      final workspace = File('pubspec.yaml').readAsStringSync();
      for (final expected in [
        (
          name: 'adele_plugin_backend_support',
          path: 'packages/plugin_backend_support',
        ),
        (name: 'agents_md_backend', path: 'plugins/agents_md/packages/backend'),
        (
          name: 'search_tools_backend',
          path: 'plugins/search_tools/packages/backend',
        ),
        (
          name: 'filesystem_tools_backend',
          path: 'plugins/filesystem_tools/packages/backend',
        ),
        (
          name: 'command_tools_backend',
          path: 'plugins/command_tools/packages/backend',
        ),
      ]) {
        final target = lookupTestTarget(expected.name);
        expect(target.path, expected.path);
        expect(target.executable, 'dart');
        expect(target.argumentsFor(ci: true), ['test']);
        expect(target.linuxDesktopDeps, isFalse);
        final analysis = analysisTargets.singleWhere(
          (target) => target.name == expected.name,
        );
        expect(analysis.path, expected.path);
        expect(analysis.flutter, isFalse);
        expect(workspace, contains('  - ${expected.path}\n'));
      }
      expect(workspace, contains('  - plugins/agents_md\n'));
      expect(
        File('app/lib/core/adele_runtime.dart').readAsStringSync(),
        isNot(contains('AgentsMdPlugin')),
      );
      expect(
        File('app/lib/core/adele_runtime.dart').readAsStringSync(),
        isNot(contains('FilesystemToolsPlugin')),
      );
      final runtime = File(
        'app/lib/core/adele_runtime.dart',
      ).readAsStringSync();
      expect(runtime, isNot(contains('CommandToolsPlugin')));
      expect(runtime, isNot(contains('includeCommandTools')));
      const selfHostingPath =
          'app/tool/self_hosting/development_self_hosting.dart';
      final selfHosting = File(selfHostingPath).readAsStringSync();
      for (final package in ['search_tools', 'command_tools']) {
        expect(
          selfHosting,
          isNot(contains('package:$package')),
          reason: selfHostingPath,
        );
      }
    });

    test('discovers the UI API with the Flutter runner policy', () {
      final TestTarget target = lookupTestTarget('adele_ui');

      expect(target.path, 'packages/ui');
      expect(target.executable, 'flutter');
      expect(target.argumentsFor(), <String>['test']);
      expect(target.argumentsFor(ci: true), <String>['test']);
      expect(target.linuxDesktopDeps, isFalse);
      expect(target.ciTestConcurrency, isNull);
    });

    test('discovers the local selector without Linux desktop dependencies', () {
      final TestOptions options = parseTestOptions(<String>[
        '--target',
        'local_directory_project_frontend',
        '--ci',
      ]);
      final TestTarget target = lookupTestTarget(options.target!);

      expect(target.path, 'plugins/local_directory_project/packages/frontend');
      expect(target.executable, 'flutter');
      expect(target.argumentsFor(), <String>['test']);
      expect(target.argumentsFor(ci: options.ci), <String>['test']);
      expect(target.linuxDesktopDeps, isFalse);
      expect(target.ciTestConcurrency, isNull);
    });

    test('discovers the local provider as a pure-Dart target', () {
      final target = lookupTestTarget('local_directory_project_backend');
      expect(target.path, 'plugins/local_directory_project/packages/backend');
      expect(target.executable, 'dart');
      expect(target.argumentsFor(ci: true), ['test']);
      expect(target.linuxDesktopDeps, isFalse);
      expect(target.ciTestConcurrency, isNull);
      final analysis = analysisTargets.singleWhere(
        (item) => item.name == target.name,
      );
      expect(analysis.path, target.path);
      expect(analysis.flutter, isFalse);
    });

    for (final (name, plugin, file) in [
      (
        'filesystem_tools_frontend',
        'filesystem_tools',
        'filesystem_tools_frontend_eval_test.dart',
      ),
      (
        'chat_strategy_frontend',
        'chat_strategy',
        'chat_frontend_eval_test.dart',
      ),
      (
        'command_tools_frontend',
        'command_tools',
        'command_output_frontend_eval_test.dart',
      ),
      ('openai_frontend', 'openai', 'openai_activity_frontend_eval_test.dart'),
    ]) {
      test('discovers $name as an independent Flutter integration target', () {
        final options = parseTestOptions(['--target', name, '--ci']);
        final target = lookupTestTarget(options.target!);
        final path = 'plugins/$plugin/packages/frontend';
        expect(testTargets.where((entry) => entry.name == name), hasLength(1));
        expect(target.path, path);
        expect(target.nativeCodeEditor, isFalse);
        expect(target.executable, 'flutter');
        expect(target.argumentsFor(), ['test']);
        expect(target.argumentsFor(ci: options.ci), ['test']);
        expect(target.linuxDesktopDeps, isFalse);
        expect(target.ciTestConcurrency, isNull);
        final analysis = analysisTargets.singleWhere(
          (entry) => entry.name == name,
        );
        expect(analysis.path, path);
        expect(analysis.flutter, isTrue);
        expect(File('$path/test/$file').existsSync(), isTrue);
        if (name == 'command_tools_frontend') {
          expect(
            File(
              '$path/test/command_tools_inspection_frontend_eval_test.dart',
            ).existsSync(),
            isTrue,
          );
        }
        expect(File('app/test/$file').existsSync(), isFalse);
        final plan = jsonDecode(testPlanJson()) as Map<String, Object?>;
        final entries = (plan['include']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .where((entry) => entry['name'] == name);
        expect(entries, hasLength(1));
        expect(entries.single['linuxDesktopDeps'], isFalse);
        expect(entries.single['nativeCodeEditor'], isFalse);
        expect(entries.single['ciTestConcurrency'], isNull);
        expect(lookupTestTarget('adele_desktop').path, 'app');
        expect(
          File(
            'app/test/core/normal_chatgpt_run_integration_test.dart',
          ).existsSync(),
          isTrue,
        );
      });
    }

    test('discovers the frontend-only Task Browser in workspace and CI', () {
      const path = 'plugins/task_browser/packages/frontend';
      final target = lookupTestTarget('task_browser_frontend');
      expect(target.path, path);
      expect(target.executable, 'flutter');
      expect(target.argumentsFor(ci: true), ['test']);
      expect(target.linuxDesktopDeps, isFalse);
      final analysis = analysisTargets.singleWhere(
        (entry) => entry.name == target.name,
      );
      expect(analysis.path, path);
      expect(analysis.flutter, isTrue);
      expect(File('pubspec.yaml').readAsStringSync(), contains('  - $path\n'));
      expect(
        Directory('plugins/task_browser/packages/backend').existsSync(),
        isFalse,
      );
      expect(stockFrontendDescriptors['dev.adele.plugin.task-browser'], [
        {
          'role': 'taskBrowser',
          'extensionId': 'dev.adele.plugin.task-browser.task-browser',
          'displayName': 'Task Browser',
          'library': 'package:task_browser_frontend/task_browser_frontend.dart',
          'entrypoint': 'createTaskBrowser',
        },
      ]);
    });

    test('discovers the frontend-only Terminal in workspace and CI', () {
      const path = 'plugins/terminal/packages/frontend';
      final target = lookupTestTarget('terminal_frontend');
      expect(target.path, path);
      expect(target.executable, 'flutter');
      expect(target.argumentsFor(ci: true), ['test']);
      expect(target.linuxDesktopDeps, isFalse);
      expect(target.ciTestConcurrency, isNull);
      final analysis = analysisTargets.singleWhere(
        (entry) => entry.name == target.name,
      );
      expect(analysis.path, path);
      expect(analysis.flutter, isTrue);
      expect(File('pubspec.yaml').readAsStringSync(), contains('  - $path\n'));
      expect(
        Directory('plugins/terminal/packages/backend').existsSync(),
        isFalse,
      );
      expect(File('plugins/terminal/pubspec.yaml').existsSync(), isFalse);
      final manifest =
          loadYaml(File('$path/pubspec.yaml').readAsStringSync()) as YamlMap;
      expect(manifest['name'], 'terminal_frontend');
      expect(manifest['resolution'], 'workspace');
      expect(manifest['dependencies'], {
        'adele_ui': '^0.1.0',
        'flutter': {'sdk': 'flutter'},
      });
      expect(
        (manifest['dev_dependencies'] as YamlMap).keys,
        containsAll(['flutter_test', 'dart_eval', 'flutter_eval']),
      );
      expect(stockFrontendDescriptors['dev.adele.plugin.terminal'], [
        {
          'role': 'console',
          'extensionId': 'dev.adele.plugin.terminal.console',
          'library': 'package:terminal_frontend/terminal_frontend.dart',
          'entrypoint': 'buildTerminal',
          'actions': [
            {
              'id': 'new-terminal',
              'label': 'New Terminal',
              'entrypoint': 'newTerminal',
            },
          ],
        },
      ]);
      expect(stockFrontendExtensionDescriptors['dev.adele.plugin.terminal'], [
        {
          'kind': 'consoleActionCommand',
          'extensionId': 'dev.adele.plugin.terminal.command.new-terminal',
          'commandId': 'dev.adele.plugin.terminal.new-terminal',
          'consoleExtensionId': 'dev.adele.plugin.terminal.console',
          'actionId': 'new-terminal',
        },
      ]);
    });

    test(
      'discovers frontend-only Source with explicit opt-in Main Content',
      () {
        const path = 'plugins/source_editor/packages/frontend';
        final target = lookupTestTarget('source_editor_frontend');
        expect(
          testTargets.where((entry) => entry.name == target.name),
          hasLength(1),
        );
        expect(target.path, path);
        expect(target.executable, 'flutter');
        expect(target.nativeCodeEditor, isTrue);
        expect(
          File('$path/test/source_documents_test.dart').existsSync(),
          isTrue,
        );
        expect(
          File('$path/test/source_editor_host_test.dart').existsSync(),
          isTrue,
        );
        expect(
          File('app/test/source_editor_host_test.dart').existsSync(),
          isFalse,
        );
        expect(target.argumentsFor(ci: true), ['test']);
        expect(target.linuxDesktopDeps, isFalse);
        expect(target.ciTestConcurrency, isNull);
        final analysis = analysisTargets.singleWhere(
          (entry) => entry.name == target.name,
        );
        expect(analysis.path, path);
        expect(analysis.flutter, isTrue);
        expect(
          File('pubspec.yaml').readAsStringSync(),
          contains('  - $path\n'),
        );
        expect(
          Directory('plugins/source_editor/packages/backend').existsSync(),
          isFalse,
        );
        expect(
          File('plugins/source_editor/pubspec.yaml').existsSync(),
          isFalse,
        );
        final manifest =
            loadYaml(File('$path/pubspec.yaml').readAsStringSync()) as YamlMap;
        expect(manifest['name'], 'source_editor_frontend');
        expect(manifest['resolution'], 'workspace');
        expect(manifest['dependencies'], {
          'adele_ui': '^0.1.0',
          'flutter': {'sdk': 'flutter'},
        });
        expect(stockFrontendDescriptors['dev.adele.source-editor'], [
          {
            'role': 'mainContent',
            'extensionId': 'dev.adele.source-editor.main-content',
            'library': 'package:source_editor_frontend/main.dart',
            'initialize': 'initializeSource',
            'entrypoint': 'sourcePane',
            'order': 300,
            'actions': [
              {
                'id': 'open',
                'label': 'Open Source...',
                'entrypoint': 'openSourceInput',
              },
            ],
            'operations': {
              'display': 'displaySource',
              'save': 'saveSource',
              'close': 'closeSource',
              'exit': 'closeSources',
            },
            'closeOperation': 'close',
            'exitOperation': 'exit',
            'displaySourceFileOperation': 'display',
            'retainedData': true,
            'nativeCodeEditor': true,
            'environmentTextFiles': true,
          },
        ]);
        expect(stockFrontendExtensionDescriptors['dev.adele.source-editor'], [
          {
            'kind': 'mainContentActionCommand',
            'extensionId': 'dev.adele.source-editor.command.open-source',
            'commandId': 'dev.adele.source-editor.open-source',
            'mainContentExtensionId': 'dev.adele.source-editor.main-content',
            'actionId': 'open',
          },
        ]);
        final compiler = File(
          'app/tool/source_editor_frontend_compiler.dart',
        ).readAsStringSync();
        for (final declaration in [
          'MainContentDeclarations',
          'CodeEditorDeclarations',
          'ContributionDeclarations',
        ]) {
          expect(compiler, contains('..addPlugin(const $declaration())'));
        }
        for (final stub in [
          'main_content_bridge.dart',
          'code_editor_bridge.dart',
          'contribution_bridge.dart',
        ]) {
          expect(compiler, contains("'$stub'"));
        }
        expect(
          compiler,
          contains('plugins/source_editor/packages/frontend/lib'),
        );
        expect(compiler, isNot(contains('package:code_forge/')));
      },
    );

    test('rejects an unknown target', () {
      expect(
        () => lookupTestTarget('missing'),
        throwsA(
          isA<TestUsageException>().having(
            (TestUsageException failure) => failure.message,
            'message',
            contains('Unknown test target: missing'),
          ),
        ),
      );
    });
  });

  test('discovers UI and stock frontend packages for Flutter analysis', () {
    for (final ({String name, String path}) expected
        in <({String name, String path})>[
          (name: 'adele_ui', path: 'packages/ui'),
          (
            name: 'chat_strategy_frontend',
            path: 'plugins/chat_strategy/packages/frontend',
          ),
          (
            name: 'filesystem_tools_frontend',
            path: 'plugins/filesystem_tools/packages/frontend',
          ),
          (
            name: 'command_tools_frontend',
            path: 'plugins/command_tools/packages/frontend',
          ),
          (name: 'openai_frontend', path: 'plugins/openai/packages/frontend'),
          (
            name: 'local_directory_project_frontend',
            path: 'plugins/local_directory_project/packages/frontend',
          ),
          (
            name: 'terminal_frontend',
            path: 'plugins/terminal/packages/frontend',
          ),
          (
            name: 'source_editor_frontend',
            path: 'plugins/source_editor/packages/frontend',
          ),
        ]) {
      final target = analysisTargets.singleWhere(
        (package) => package.name == expected.name,
      );
      expect(target.path, expected.path);
      expect(target.flutter, isTrue);
    }
    for (final String name in [
      'chat_strategy_contract',
      'chat_strategy_backend',
      'filesystem_tools_plugin',
      'command_tools_plugin',
      'command_tools_contract',
      'openai_contract',
    ]) {
      expect(
        analysisTargets.singleWhere((package) => package.name == name).flutter,
        isFalse,
      );
      expect(lookupTestTarget(name).executable, 'dart');
    }
  });

  test(
    'stock descriptors name existing frontend entrypoints and sibling actions',
    () {
      expect(stockFrontendDescriptors, hasLength(7));
      expect(stockFrontendExtensionDescriptors, hasLength(3));
      final config = File('.dart_tool/package_config.json').absolute;
      final packages =
          (jsonDecode(config.readAsStringSync())
                  as Map<String, dynamic>)['packages']
              as List<dynamic>;
      for (final entry in [
        ...stockFrontendDescriptors.entries,
        ...stockFrontendExtensionDescriptors.entries,
      ]) {
        final descriptors = entry.value;
        expect(
          descriptors,
          hasLength(
            identical(
                  descriptors,
                  stockFrontendDescriptors['dev.adele.plugin.command-tools'],
                )
                ? 2
                : 1,
          ),
        );
        for (final descriptor in descriptors) {
          if (descriptor['kind'] == 'consoleActionCommand' ||
              descriptor['kind'] == 'mainContentActionCommand') {
            final console = descriptor['kind'] == 'consoleActionCommand';
            final targetField = console
                ? 'consoleExtensionId'
                : 'mainContentExtensionId';
            final target = stockFrontendDescriptors[entry.key]!.singleWhere(
              (presentation) =>
                  presentation['role'] ==
                      (console ? 'console' : 'mainContent') &&
                  presentation['extensionId'] == descriptor[targetField],
            );
            if (console) expect(target['readOnly'], isNot(true));
            final actions = target['actions']! as List<Map<String, Object?>>;
            expect(
              actions.where((action) => action['id'] == descriptor['actionId']),
              hasLength(1),
            );
            expect(
              descriptor.keys,
              unorderedEquals([
                'kind',
                'extensionId',
                'commandId',
                targetField,
                'actionId',
              ]),
            );
            continue;
          }
          final library = Uri.parse(descriptor['library']! as String);
          expect(library.scheme, 'package');
          final package = packages.cast<Map<String, dynamic>>().singleWhere(
            (package) => package['name'] == library.pathSegments.first,
          );
          final packageRoot = Directory.fromUri(
            config.uri.resolve(package['rootUri'] as String),
          );
          final source = File.fromUri(
            packageRoot.uri
                .resolve(package['packageUri'] as String)
                .resolve(library.pathSegments.skip(1).join('/')),
          ).readAsStringSync();
          for (final field in [
            'entrypoint',
            'initialize',
            'inspectionEntrypoint',
            'compactEntrypoint',
          ]) {
            if (descriptor[field] case final String entrypoint) {
              expect(
                source,
                matches(
                  RegExp(
                    (descriptor['kind'] == 'projectSelector'
                            ? r'\bFuture<String\?>\s+'
                            : field == 'initialize'
                            ? r'\b(?:void|Future<void>)\s+'
                            : r'\b(?:Widget|Future<Widget>)\s+') +
                        RegExp.escape(entrypoint) +
                        r'\s*\(',
                  ),
                ),
                reason: '${descriptor['library']}::$entrypoint',
              );
            }
          }
          if (descriptor['actions'] case final List<Object?> actions) {
            for (final action in actions.cast<Map<String, Object?>>()) {
              final entrypoint = action['entrypoint']! as String;
              expect(
                source,
                matches(
                  RegExp(
                    (descriptor['role'] == 'mainContent'
                            ? r'\b(?:Widget|Future<Widget>)\s+'
                            : r'\bFuture<List<dynamic>>\s+') +
                        RegExp.escape(entrypoint) +
                        r'\s*\(',
                  ),
                ),
                reason: '${descriptor['library']}::$entrypoint',
              );
            }
          }
          if (descriptor['operations']
              case final Map<String, Object?> operations) {
            for (final entrypoint in operations.values.cast<String>()) {
              expect(
                source,
                matches(
                  RegExp(
                    r'\bFuture<Map<String,\s*dynamic>>\s+' +
                        RegExp.escape(entrypoint) +
                        r'\s*\(',
                  ),
                ),
                reason: '${descriptor['library']}::$entrypoint',
              );
            }
          }
        }
      }
      final command =
          stockFrontendDescriptors['dev.adele.plugin.command-tools']!;
      final inspection = command.singleWhere(
        (value) => value['role'] == 'toolActivity',
      );
      final output = command.singleWhere((value) => value['role'] == 'console');
      expect(inspection['backendServices'], ['command.output']);
      expect(inspection['consoleExtensions'], [output['extensionId']]);
      expect(output['backendServices'], ['command.output']);
      expect(output['readOnly'], isTrue);
      expect(output['keepAlive'], isTrue);
      expect(output['actions'], isEmpty);
      expect(
        stockFrontendDescriptors.values
            .expand((descriptors) => descriptors)
            .where((descriptor) => descriptor['keepAlive'] == true),
        [output],
      );
    },
  );

  test('Local Directory Project components are separate workspace members', () {
    const root = 'plugins/local_directory_project';
    final workspace = File('pubspec.yaml').readAsStringSync();
    expect(workspace, isNot(contains('  - $root\n')));
    expect(File('$root/pubspec.yaml').existsSync(), isFalse);
    expect(analysisTargets.any((target) => target.path == root), isFalse);
    for (final component in ['backend', 'frontend']) {
      final path = '$root/packages/$component';
      final name = 'local_directory_project_$component';
      expect(workspace, contains('  - $path\n'));
      expect(
        File('$path/pubspec.yaml').readAsStringSync(),
        startsWith('name: $name\n'),
      );
      expect(lookupTestTarget(name).path, path);
      expect(
        analysisTargets.singleWhere((target) => target.name == name).path,
        path,
      );
    }
    final frontend = File(
      '$root/packages/frontend/pubspec.yaml',
    ).readAsStringSync();
    expect(frontend, contains('  adele_ui: ^0.1.0\n'));
    expect(frontend, contains('resolution: workspace\n'));
    final backend = File(
      '$root/packages/backend/pubspec.yaml',
    ).readAsStringSync();
    expect(backend, contains('  adele_core_extensions: ^0.1.0\n'));
    expect(backend, contains('resolution: workspace\n'));
    expect(backend, isNot(contains('flutter:')));
    expect(backend, isNot(contains('local_directory_project_frontend:')));
    for (final forbidden in [
      'local_directory_project_backend:',
      'file_selector:',
      'adele_desktop:',
      'plugin_runtime:',
      'adele_product:',
    ]) {
      expect(frontend, isNot(contains(forbidden)));
    }
    final app = File('app/pubspec.yaml').readAsStringSync();
    final parts = app.split('dev_dependencies:');
    expect(parts.first, contains('  file_selector: ^1.1.0\n'));
    expect(parts.first, isNot(contains('file_selector_platform_interface:')));
    expect(
      parts.last,
      contains('  file_selector_platform_interface: ^2.7.0\n'),
    );
    expect(
      stockFrontendExtensionDescriptors['dev.adele.plugin.local-directory-project'],
      [
        {
          'kind': 'projectSelector',
          'extensionId':
              'dev.adele.plugin.local-directory-project.project-selector',
          'projectProviderId': 'dev.adele.project.local-directory',
          'displayName': 'Open Local Directory...',
          'library':
              'package:local_directory_project_frontend/local_directory_project_frontend.dart',
          'entrypoint': 'selectProject',
        },
      ],
    );
  });

  test('tool frontends are workspace members isolated from headless tools', () {
    final String workspace = File('pubspec.yaml').readAsStringSync();
    for (final String tool in ['filesystem_tools', 'command_tools']) {
      final String path = 'plugins/$tool/packages/frontend';
      expect(workspace, contains('  - $path\n'));
      final String frontend = File('$path/pubspec.yaml').readAsStringSync();
      expect(frontend, contains('name: ${tool}_frontend\n'));
      expect(frontend, contains('resolution: workspace\n'));
      expect(frontend, contains('  adele_ui: ^0.1.0\n'));
      expect(frontend, contains('    sdk: flutter\n'));
      final production = frontend.split('dev_dependencies:').first;
      expect(production, isNot(contains('${tool}_plugin')));
      expect(production, isNot(contains('adele_desktop')));
      expect(production, isNot(contains('plugin_runtime')));
      final String headless = File(
        'plugins/$tool/pubspec.yaml',
      ).readAsStringSync();
      expect(headless, isNot(contains('flutter:')));
      expect(headless, isNot(contains('adele_ui:')));
      expect(headless, isNot(contains('${tool}_frontend')));
    }
    // Mixed/generic Inspection composition remains application-owned.
    expect(lookupTestTarget('adele_desktop').argumentsFor(), ['test']);
    expect(
      File('app/test/tool_inspection_frontend_eval_test.dart').existsSync(),
      isTrue,
    );
  });

  test('compact composition preserves plugin parsing and authority boundaries', () {
    final files = <File>[
      for (final path in [
        'app/lib/ui/main_content',
        'app/lib/ui/execution',
        'app/lib/ui/activity',
        'app/lib/ui/inspection',
      ])
        ...Directory(path).listSync(recursive: true).whereType<File>(),
    ];
    for (final file in files) {
      if (!file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      for (final forbidden in [
        "['relativePath']",
        "['edits']",
        "['program']",
        "['arguments']",
        "['summaryParts']",
      ]) {
        expect(source, isNot(contains(forbidden)), reason: file.path);
      }
    }
    for (final path in [
      'packages/ui/lib/tool_activity_compact_presentation.dart',
      'packages/ui/lib/model_native_activity_compact_presentation.dart',
      'plugins/filesystem_tools/packages/frontend/lib/filesystem_tools_frontend.dart',
      'plugins/command_tools/packages/frontend/lib/command_tools_frontend.dart',
      'plugins/openai/packages/frontend/lib/openai_frontend.dart',
    ]) {
      final source = File(path).readAsStringSync();
      for (final forbidden in [
        'openInspection(',
        'inspectActivity(',
        'ToolApprovalResolution',
        'resolveApproval(',
        'package:adele_desktop/',
        'package:agent_kernel/',
      ]) {
        expect(source, isNot(contains(forbidden)), reason: path);
      }
    }
  });

  test('target data preserves package-specific runners and timeouts', () {
    expect(
      <String>[
        for (final TestTarget target in testTargets)
          '${target.name}|${target.executable}|${target.path}|'
              '${target.argumentsFor().join(' ')}',
      ],
      const <String>[
        'adele_tools|dart|.|test test/tools',
        'adele_contract|dart|packages/contract|test',
        'contract_codegen|dart|packages/contract_codegen|test --concurrency 2',
        'adele_plugin_api|dart|packages/plugin_api|test',
        'adele_plugin_backend_support|dart|packages/plugin_backend_support|test',
        'adele_product|dart|packages/product|test',
        'adele_core_extensions|dart|packages/core_extensions|test',
        'adele_project_storage|dart|packages/project_storage|test',
        'adele_ui|flutter|packages/ui|test',
        'adele_orchestration|dart|packages/orchestration|test',
        'adele_environment|dart|packages/environment|test',
        'adele_model_tool|dart|packages/model_tool|test',
        'adele_model_provider|dart|packages/model_provider|test',
        'adele_capabilities|dart|packages/capabilities|test',
        'agent_kernel|dart|packages/agent_kernel|test',
        'plugin_builder|dart|packages/plugin_builder|test',
        'plugin_runtime|dart|packages/plugin_runtime|test --timeout 10s',
        'plugin_backend_host|dart|packages/plugin_backend_host|test',
        'resource_inspector_contract|dart|plugins/resource_inspector/packages/contract|test --timeout 4m',
        'git_environment_backend|dart|plugins/git_environment/packages/backend|test --timeout 4m',
        'filesystem_tools_plugin|dart|plugins/filesystem_tools|test',
        'filesystem_tools_backend|dart|plugins/filesystem_tools/packages/backend|test',
        'filesystem_tools_frontend|flutter|plugins/filesystem_tools/packages/frontend|test',
        'search_tools_plugin|dart|plugins/search_tools|test',
        'search_tools_backend|dart|plugins/search_tools/packages/backend|test',
        'command_tools_plugin|dart|plugins/command_tools|test',
        'command_tools_backend|dart|plugins/command_tools/packages/backend|test',
        'command_tools_contract|dart|plugins/command_tools/packages/contract|test',
        'command_tools_frontend|flutter|plugins/command_tools/packages/frontend|test',
        'agents_md_plugin|dart|plugins/agents_md|test',
        'agents_md_backend|dart|plugins/agents_md/packages/backend|test',
        'chat_strategy_contract|dart|plugins/chat_strategy/packages/contract|test',
        'chat_strategy_backend|dart|plugins/chat_strategy/packages/backend|test',
        'chat_strategy_frontend|flutter|plugins/chat_strategy/packages/frontend|test',
        'session_evaluator_contract|dart|plugins/session_evaluator/packages/contract|test',
        'session_evaluator_backend|dart|plugins/session_evaluator/packages/backend|test',
        'local_directory_project_backend|dart|plugins/local_directory_project/packages/backend|test',
        'local_directory_project_frontend|flutter|plugins/local_directory_project/packages/frontend|test',
        'task_browser_frontend|flutter|plugins/task_browser/packages/frontend|test',
        'terminal_frontend|flutter|plugins/terminal/packages/frontend|test',
        'source_editor_frontend|flutter|plugins/source_editor/packages/frontend|test',
        'scripted_model_contract|dart|plugins/scripted_model/packages/contract|test --timeout 4m',
        'scripted_model_backend|dart|plugins/scripted_model/packages/backend|test',
        'openai_model_provider_backend|dart|plugins/openai/packages/backend|test --timeout 4m',
        'openai_contract|dart|plugins/openai/packages/contract|test',
        'openai_frontend|flutter|plugins/openai/packages/frontend|test',
        'workspace_demo_contract|dart|plugins/workspace_demo/packages/contract|test',
        'workspace_demo_backend|dart|plugins/workspace_demo/packages/backend|test',
        'adele_desktop|flutter|app|test',
      ],
    );
    final TestTarget codegen = lookupTestTarget('contract_codegen');
    expect(codegen.argumentsFor(), <String>['test', '--concurrency', '2']);
    expect(codegen.argumentsFor(ci: true), <String>[
      'test',
      '--concurrency',
      '4',
    ]);
    expect(lookupTestTarget('plugin_runtime').argumentsFor(ci: true), <String>[
      'test',
      '--timeout',
      '10s',
    ]);
    expect(
      lookupTestTarget('git_environment_backend').argumentsFor(ci: true),
      <String>['test', '--timeout', '4m', '--concurrency', '1'],
    );
  });

  test('OpenAI presentation preserves package and raw-evidence boundaries', () {
    final String workspace = File(
      'plugins/openai/pubspec.yaml',
    ).readAsStringSync();
    expect(workspace, contains('  - packages/contract\n'));
    expect(workspace, contains('  - packages/backend\n'));
    expect(workspace, contains('  - packages/frontend\n'));
    expect(workspace, isNot(contains('packages/native_activity')));
    expect(
      File('plugins/openai/packages/native_activity/pubspec.yaml').existsSync(),
      isFalse,
    );
    final String backend = File(
      'plugins/openai/packages/backend/pubspec.yaml',
    ).readAsStringSync();
    final String shared = File(
      'plugins/openai/packages/contract/pubspec.yaml',
    ).readAsStringSync();
    final String frontend = File(
      'plugins/openai/packages/frontend/pubspec.yaml',
    ).readAsStringSync();
    expect(backend, contains('  openai_contract: ^0.1.0\n'));
    for (final manifest in [backend, shared]) {
      expect(manifest, isNot(contains('flutter:')));
      expect(manifest, isNot(contains('adele_ui:')));
      expect(manifest, isNot(contains('openai_frontend:')));
    }
    expect(frontend, contains('  adele_ui: ^0.1.0\n'));
    expect(frontend, isNot(contains('openai_model_provider_backend:')));
    expect(lookupTestTarget('openai_contract').executable, 'dart');
    final String app = File('app/pubspec.yaml').readAsStringSync();
    for (final manifest in [app, backend, shared, frontend]) {
      expect(manifest, isNot(contains('openai_native_activity')));
    }
    final String activation = File(
      'app/lib/frontend/application_frontend_bootstrap.dart',
    ).readAsStringSync();
    expect(activation, contains('PreparedModelNativeActivityPresentation'));
    for (final forbidden in [
      'openAiReasoningSummaryPresentationKind',
      ...stockFrontendDescriptors['dev.adele.openai']!.single.entries
          .where((entry) => entry.key != 'role')
          .map((entry) => entry.value as String),
      'projectOpenAi',
      'providerNativeMetadata',
      'encrypted_content',
      "['summary']",
      "['summaryParts']",
    ]) {
      expect(activation, isNot(contains(forbidden)), reason: forbidden);
    }
    for (final file in Directory(
      'plugins/openai/packages/contract/lib',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final String source = file.readAsStringSync();
      for (final forbidden in [
        'projectOpenAi',
        'dart:io',
        'package:flutter',
        'ModelProviderOutput',
        'ModelNativeOutput',
      ]) {
        expect(source, isNot(contains(forbidden)), reason: file.path);
      }
    }
    expect(
      File(
        'plugins/openai/packages/frontend/test/openai_activity_frontend_eval_test.dart',
      ).existsSync(),
      isTrue,
    );

    // Provider-specific raw-item interpretation must not drift into UI hosts.
    for (final directory in ['app/lib/ui', 'app/lib/frontend']) {
      for (final file in Directory(
        directory,
      ).listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final String source = file.readAsStringSync();
        for (final forbidden in [
          'openai.responses.item.v1',
          'encrypted_content',
          "['summary']",
          "['summaryParts']",
        ]) {
          expect(source, isNot(contains(forbidden)), reason: file.path);
        }
      }
    }
    for (final path in [
      'packages/ui/lib/model_native_activity_bridge.dart',
      'packages/ui/lib/model_native_activity_presentation.dart',
      'app/lib/frontend/model_native_activity_bridge.dart',
      'plugins/openai/packages/frontend/lib/openai_frontend.dart',
    ]) {
      final String source = File(path).readAsStringSync();
      for (final forbidden in [
        'ModelNativeEnvelope',
        'ModelNativeOutput',
        'ModelPort',
        'ModelProvider',
        'SessionController',
        'encrypted_content',
        'credential',
      ]) {
        expect(source, isNot(contains(forbidden)), reason: path);
      }
    }
  });
}

List<TestTarget> _targets(int count) => <TestTarget>[
  for (int index = 0; index < count; index++)
    TestTarget(
      name: '$index',
      path: '.',
      executable: 'dart',
      arguments: const <String>[],
    ),
];

Future<void> _until(bool Function() condition) async {
  while (!condition()) {
    await Future<void>.delayed(Duration.zero);
  }
}
