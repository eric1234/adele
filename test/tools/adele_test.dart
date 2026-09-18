import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tools/adele.dart';
import '../../tools/stock_frontend_descriptors.dart';
import '../../tools/test_runner.dart';

void main() {
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
    test('accepts an exact target and rejects ambiguous combinations', () {
      final TestOptions options = parseTestOptions(<String>[
        '--target',
        'contract_codegen',
      ]);
      expect(options.target, 'contract_codegen');
      expect(options.jobs, 1);
      expect(options.ci, isFalse);
      final TestOptions ciOptions = parseTestOptions(<String>[
        '--target',
        'contract_codegen',
        '--ci',
      ]);
      expect(ciOptions.ci, isTrue);
      expect(
        () => parseTestOptions(<String>[
          '--target',
          'contract_codegen',
          '--jobs',
          '2',
        ]),
        throwsA(isA<TestUsageException>()),
      );
    });

    test('rejects missing, duplicate, equals, and unknown target options', () {
      for (final List<String> arguments in <List<String>>[
        <String>['--target'],
        <String>['--target', 'one', '--target', 'two'],
        <String>['--target=one'],
        <String>['--ci'],
        <String>['--target', 'one', '--ci', '--ci'],
        <String>['--other'],
      ]) {
        expect(
          () => parseTestOptions(arguments),
          throwsA(isA<TestUsageException>()),
          reason: arguments.toString(),
        );
      }
    });
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
        include,
        everyElement(
          isA<Map<String, Object?>>().having(
            (Map<String, Object?> item) => item.keys,
            'keys',
            unorderedEquals(<String>[
              'name',
              'linuxDesktopDeps',
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
              'git_environment_backend' => 1,
              _ => null,
            },
        },
      );
    });
  });

  group('target lookup', () {
    test('returns the exact target', () {
      expect(lookupTestTarget('contract_codegen').name, 'contract_codegen');
    });

    test('discovers Chat as a pure-Dart target with default CI policy', () {
      final TestOptions options = parseTestOptions(<String>[
        '--target',
        'chat_strategy_plugin',
        '--ci',
      ]);
      final TestTarget target = lookupTestTarget(options.target!);

      expect(target.path, 'plugins/chat_strategy');
      expect(target.executable, 'dart');
      expect(target.argumentsFor(ci: options.ci), <String>['test']);
      expect(target.linuxDesktopDeps, isFalse);
      expect(target.ciTestConcurrency, isNull);
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
        File('app/pubspec.yaml').readAsStringSync(),
        isNot(contains('  agents_md_plugin:')),
      );
      expect(
        File('app/lib/core/adele_runtime.dart').readAsStringSync(),
        isNot(contains('AgentsMdPlugin')),
      );
      final app = File('app/pubspec.yaml').readAsStringSync();
      expect(
        app.split('dev_dependencies:').first,
        isNot(contains('filesystem_tools')),
      );
      expect(
        File('app/lib/core/adele_runtime.dart').readAsStringSync(),
        isNot(contains('FilesystemToolsPlugin')),
      );
      expect(
        app.split('dev_dependencies:').first,
        isNot(contains('search_tools')),
      );
      expect(
        app.split('dev_dependencies:').last,
        contains('search_tools_plugin:'),
      );
      expect(
        app.split('dev_dependencies:').first,
        isNot(contains('command_tools')),
      );
      expect(
        app.split('dev_dependencies:').last,
        contains('command_tools_plugin:'),
      );
      final runtime = File(
        'app/lib/core/adele_runtime.dart',
      ).readAsStringSync();
      expect(runtime, isNot(contains('CommandToolsPlugin')));
      expect(runtime, isNot(contains('includeCommandTools')));
      for (final path in [
        'app/lib/core/adele_runtime.dart',
        'app/lib/core/application_plugin_bootstrap.dart',
        'app/lib/development/agent/development_self_hosting.dart',
      ]) {
        expect(
          File(path).readAsStringSync(),
          isNot(contains('package:search_tools')),
          reason: path,
        );
        expect(
          File(path).readAsStringSync(),
          isNot(contains('package:command_tools')),
          reason: path,
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

    test('does not register a frontend target without standalone tests', () {
      for (final String name in [
        'chat_strategy_frontend',
        'filesystem_tools_frontend',
        'command_tools_frontend',
        'openai_frontend',
      ]) {
        expect(
          () => lookupTestTarget(name),
          throwsA(isA<TestUsageException>()),
        );
      }
    });

    test('discovers the local selector without Linux desktop dependencies', () {
      final TestOptions options = parseTestOptions(<String>[
        '--target',
        'local_directory_project_selector_frontend',
        '--ci',
      ]);
      final TestTarget target = lookupTestTarget(options.target!);

      expect(
        target.path,
        'plugins/local_directory_project_selector/packages/frontend',
      );
      expect(target.executable, 'flutter');
      expect(target.argumentsFor(), <String>['test']);
      expect(target.argumentsFor(ci: options.ci), <String>['test']);
      expect(target.linuxDesktopDeps, isFalse);
      expect(target.ciTestConcurrency, isNull);
    });

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
            name: 'local_directory_project_selector_frontend',
            path: 'plugins/local_directory_project_selector/packages/frontend',
          ),
        ]) {
      final target = analysisTargets.singleWhere(
        (package) => package.name == expected.name,
      );
      expect(target.path, expected.path);
      expect(target.flutter, isTrue);
    }
    for (final String name in [
      'chat_strategy_plugin',
      'filesystem_tools_plugin',
      'command_tools_plugin',
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
    'stock descriptors name existing frontend libraries and entrypoints',
    () {
      expect(stockFrontendDescriptors, hasLength(4));
      expect(stockFrontendExtensionDescriptors, hasLength(1));
      final config = File('.dart_tool/package_config.json').absolute;
      final packages =
          (jsonDecode(config.readAsStringSync())
                  as Map<String, dynamic>)['packages']
              as List<dynamic>;
      for (final descriptors in [
        ...stockFrontendDescriptors.values,
        ...stockFrontendExtensionDescriptors.values,
      ]) {
        expect(descriptors, hasLength(1));
        for (final descriptor in descriptors) {
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
                            : r'\bWidget\s+') +
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
    },
  );

  test(
    'selector frontend replaces the root package without a native dependency',
    () {
      const root = 'plugins/local_directory_project_selector';
      const path = '$root/packages/frontend';
      final workspace = File('pubspec.yaml').readAsStringSync();
      expect(workspace, contains('  - $path\n'));
      expect(workspace, isNot(contains('  - $root\n')));
      expect(File('$root/pubspec.yaml').existsSync(), isFalse);
      expect(
        File(
          '$root/lib/local_directory_project_selector_plugin.dart',
        ).existsSync(),
        isFalse,
      );
      expect(
        () => lookupTestTarget('local_directory_project_selector_plugin'),
        throwsA(isA<TestUsageException>()),
      );
      expect(analysisTargets.any((target) => target.path == root), isFalse);
      final frontend = File('$path/pubspec.yaml').readAsStringSync();
      expect(frontend, contains('  adele_ui: ^0.1.0\n'));
      expect(frontend, contains('resolution: workspace\n'));
      for (final forbidden in [
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
      expect(app, isNot(contains('local_directory_project_selector_')));
      expect(stockFrontendExtensionDescriptors.values.single.single, {
        'kind': 'projectSelector',
        'extensionId':
            'dev.adele.plugin.local-directory-project-selector.project-selector',
        'displayName': 'Open Local Directory...',
        'library':
            'package:local_directory_project_selector_frontend/local_directory_project_selector_frontend.dart',
        'entrypoint': 'selectProject',
      });
    },
  );

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
      expect(frontend, isNot(contains('${tool}_plugin')));
      final String headless = File(
        'plugins/$tool/pubspec.yaml',
      ).readAsStringSync();
      expect(headless, isNot(contains('flutter:')));
      expect(headless, isNot(contains('adele_ui:')));
      expect(headless, isNot(contains('${tool}_frontend')));
    }
    // Actual EVC tests need Flutter and the app bridge, so use the app target.
    expect(lookupTestTarget('adele_desktop').argumentsFor(), ['test']);
    expect(
      File('app/test/tool_inspection_frontend_eval_test.dart').existsSync(),
      isTrue,
    );
  });

  test('compact composition preserves plugin parsing and authority boundaries', () {
    final files = <File>[
      File('app/lib/plugins/stock_chat_frontend.dart'),
      for (final path in [
        'app/lib/ui/chat',
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
        'package:filesystem_tools_frontend/',
        'package:command_tools_frontend/',
        'package:openai_frontend/',
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
        'search_tools_plugin|dart|plugins/search_tools|test',
        'search_tools_backend|dart|plugins/search_tools/packages/backend|test',
        'command_tools_plugin|dart|plugins/command_tools|test',
        'command_tools_backend|dart|plugins/command_tools/packages/backend|test',
        'agents_md_plugin|dart|plugins/agents_md|test',
        'agents_md_backend|dart|plugins/agents_md/packages/backend|test',
        'chat_strategy_plugin|dart|plugins/chat_strategy|test',
        'local_directory_project_selector_frontend|flutter|plugins/local_directory_project_selector/packages/frontend|test',
        'scripted_model_contract|dart|plugins/scripted_model/packages/contract|test --timeout 4m',
        'scripted_model_backend|dart|plugins/scripted_model/packages/backend|test',
        'openai_model_provider_backend|dart|plugins/openai/packages/backend|test --timeout 4m',
        'openai_contract|dart|plugins/openai/packages/contract|test',
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
    expect(app, contains('  openai_contract: ^0.1.0\n'));
    for (final manifest in [app, backend, shared, frontend]) {
      expect(manifest, isNot(contains('openai_native_activity')));
    }
    expect(app, isNot(contains('openai_model_provider_backend:')));
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
      'package:openai_model_provider_backend',
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
      File('app/test/openai_activity_frontend_eval_test.dart').existsSync(),
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
          'package:openai_',
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
