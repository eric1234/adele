import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// ignore: avoid_relative_lib_imports
import '../../packages/plugin_builder/lib/plugin_builder.dart';
import '../../tools/adele.dart' as tooling;
import '../../tools/contract_artifacts.dart';
import '../../tools/test_runner.dart';
import 'support/desktop_launcher_fixture.dart';
import 'support/desktop_launcher_inputs.dart';

void main() {
  const interactions = 'adele_plugin_interactions';
  const gitHosted = 'git_desktop_tests';
  const gitHostedPath = 'plugins/git/packages/desktop_tests';
  const review =
      'plugin_interactions_test/review/prepared_diff_git_integration_test.dart';
  const capture =
      'plugin_interactions_test/execution/command_output_capture_integration_test.dart';
  const stockPortable =
      'plugin_interactions_test/review/prepared_portable_git_stock_integration_test.dart';
  const inspection =
      'plugin_interactions_test/inspection/tool_inspection_interaction_test.dart';
  const wholeAppRuns = [
    ['test'],
    ['test', 'plugin_interactions_test'],
  ];

  late DesktopLauncherFixture fixture;
  setUp(() async {
    fixture = await DesktopLauncherFixture.create();
    for (final name in [
      'adele_tools',
      'git_backend',
      gitHosted,
      'adele_desktop',
    ]) {
      final target = tooling.lookupTestTarget(name);
      File(
        '${fixture.root.path}/${target.path}/${target.testDirectory}/nested/example_test.dart',
      ).createSync(recursive: true);
    }
    for (final path in [review, capture, stockPortable, inspection]) {
      File('${fixture.root.path}/app/$path').createSync(recursive: true);
    }
  });

  const dependencyCommands = ['pub-get', 'workspace-list'];

  void expectNoNativeBuild() {
    // Mock rustup writes its target directory rather than a command log entry.
    expect(
      Directory(
        '${fixture.root.path}/.adele/dependencies/code_forge-native',
      ).existsSync(),
      isFalse,
    );
  }

  Future<void> resolveWorkspace() async {
    final result = await fixture.invoke(['resolve-workspace']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(fixture.commands.readAsLinesSync(), dependencyCommands);
    expect(fixture.generationArguments.existsSync(), isFalse);
    expect(
      File(
        '${fixture.root.path}/.dart_tool/adele/contracts/freshness.json',
      ).existsSync(),
      isFalse,
    );
    expectNoNativeBuild();
  }

  test(
    'test-plan runs pre-bootstrap without generating, inspecting or compiling',
    () async {
      fixture.removeBootstrapMetadata();
      Directory(
        '${fixture.root.path}/app/plugin_interactions_test',
      ).deleteSync(recursive: true);
      Directory(
        '${fixture.root.path}/$gitHostedPath',
      ).deleteSync(recursive: true);
      final ProcessResult result = await fixture.invoke(<String>[
        'test-plan',
        '--json',
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final Map<String, Object?> plan =
          jsonDecode(result.stdout.toString()) as Map<String, Object?>;
      final entries = (plan['include']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(
        entries.map((item) => item['name']),
        containsAll([
          'adele_ui',
          'plugin_runtime',
          'adele_tools',
          'adele_plugin_backend_support',
          'agents_md_backend',
          'agent_configuration_contract',
          'agent_configuration_backend',
          'agent_configuration_frontend',
          'model_configuration_contract',
          'model_configuration_backend',
          'model_configuration_frontend',
          'conservative_tool_policy_backend',
          'search_tools_backend',
          'filesystem_tools_backend',
          'command_tools_backend',
          'session_evaluator_frontend',
          'local_directory_project_backend',
          'local_directory_project_frontend',
          'task_browser_frontend',
          'terminal_frontend',
          'source_editor_frontend',
        ]),
      );
      expect(
        entries
            .where((item) => item['name'] == interactions)
            .map((item) => item['shard']),
        [1, 2],
      );
      expect(entries.singleWhere((entry) => entry['name'] == gitHosted), {
        'name': gitHosted,
        'displayName': gitHosted,
        'shard': null,
        'shardCount': 1,
        'ciTestConcurrency': 1,
        'nativeToml': true,
        'nativeCodeEditor': false,
        'linuxDesktopDeps': false,
        'linuxPtyDeps': false,
      });
      expect(fixture.commands.existsSync(), isFalse);
      expect(fixture.generatedContract.existsSync(), isFalse);
      expect(
        Directory('${fixture.root.path}/.dart_tool').existsSync(),
        isFalse,
      );
      expect(Directory('${fixture.root.path}/.adele').existsSync(), isFalse);
    },
  );

  test('format check remains available before bootstrap', () async {
    fixture.removeBootstrapMetadata();
    final result = await fixture.invoke(['format', '--check']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(fixture.commands.readAsLinesSync(), ['format-check']);
    expect(fixture.generatedContract.existsSync(), isFalse);
    expect(Directory('${fixture.root.path}/.adele').existsSync(), isFalse);
  });

  test('invalid test target fails before generation or workers', () async {
    final result = await fixture.invoke(['test', '--target', 'not-a-target']);
    expect(result.exitCode, 64);
    expect(result.stderr, contains('Unknown test target: not-a-target'));
    expect(fixture.commands.existsSync(), isFalse);
    expect(fixture.generatedContract.existsSync(), isFalse);
    expect(result.stdout, isNot(contains('START test:')));
  });

  test('unknown commands remain SDK-only', () async {
    fixture.removeBootstrapMetadata();
    // Unknown commands must not prepare dependencies or invoke external tools.
    fixture.environment['PATH'] = '${fixture.root.path}/no-external-tools';
    final unknown = await fixture.invoke(['not-a-command']);
    expect(unknown.exitCode, 64);
    expect(unknown.stderr, isEmpty);
    final retired = await fixture.invoke(['probe-code-editor']);
    expect(retired.exitCode, unknown.exitCode);
    expect(retired.stdout, unknown.stdout);
    expect(retired.stderr, unknown.stderr);
    expect(retired.stdout, isNot(contains('probe-code-editor')));
    expect(fixture.commands.existsSync(), isFalse);
    expect(fixture.generatedContract.existsSync(), isFalse);
    expect(Directory('${fixture.root.path}/.adele').existsSync(), isFalse);
    expect(Directory('${fixture.root.path}/.dart_tool').existsSync(), isFalse);
    expect(File('${fixture.root.path}/pubspec.yaml').existsSync(), isFalse);
  });

  for (final arguments in [
    ['help'],
    ['--help'],
    ['prepare-code-editor', '--invalid'],
    ['prepare-rich-editor', '--invalid'],
    ['prepare-rich-editor', '--archive'],
    ['prepare-rich-editor', '--reprepare', '--reprepare'],
    ['build-code-editor-tests', '--invalid'],
    ['editor-smoke'],
    ['editor-smoke', 'linux', '--invalid'],
    ['bootstrap', '--invalid'],
    ['resolve-workspace', '--invalid'],
    ['analyze', '--invalid'],
    ['build', 'linux', '--invalid'],
    ['test', '--jobs', '0'],
    ['test', '--target=$interactions', '--ci', '--shard=3'],
  ]) {
    test(
      '${arguments.join(' ')} never prepares source or invokes tools',
      () async {
        final result = await fixture.invoke(arguments);
        expect(result.exitCode, arguments.first.contains('help') ? 0 : 64);
        if (arguments.first == 'resolve-workspace') {
          expect(result.stderr, contains('resolve-workspace takes no options'));
        }
        expect(fixture.commands.existsSync(), isFalse);
        expect(Directory('${fixture.root.path}/.adele').existsSync(), isFalse);
      },
    );
  }

  for (final arguments in [
    ['bootstrap'],
    ['resolve-workspace'],
    ['analyze'],
    ['test', '--target', 'adele_tools'],
    ['build', 'linux'],
    ['run', 'linux'],
  ]) {
    for (final (command, package, file) in [
      ('prepare-code-editor', 'code_forge', 'code.dart'),
      ('prepare-rich-editor', 'appflowy_editor', 'editor.dart'),
    ]) {
      test(
        '${arguments.join(' ')} refuses altered $package before consumers',
        () async {
          final prepared = await fixture.invoke([command]);
          expect(prepared.exitCode, 0, reason: '${prepared.stderr}');
          File(
            '${fixture.root.path}/.adele/dependencies/$package/lib/$file',
          ).writeAsStringSync('tampered');
          final result = await fixture.invoke(arguments);
          expect(result.exitCode, 1);
          expect(result.stderr, contains('Stale or altered'));
          expect(fixture.commands.existsSync(), isFalse);
        },
      );
    }
  }

  test(
    'failed native build prevents desktop test workers and any fallback',
    () async {
      fixture.environment['ADELE_TEST_FAIL_CODEFORGE_NATIVE'] = '1';
      final result = await fixture.invoke([
        'test',
        '--target',
        'adele_desktop',
      ]);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('CodeForge rustup failed (35)'));
      expect(fixture.commands.readAsLinesSync(), ['generate|path']);
      expect(result.stdout, isNot(contains('START test:')));
    },
  );

  test('bootstrap generates once after both dependency commands', () async {
    final result = await fixture.invoke(['bootstrap']);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(fixture.commands.readAsLinesSync(), [
      ...dependencyCommands,
      'generate|path',
    ]);
    fixture.expectGenerationArguments();
    expect(
      fixture.generatedContract.readAsStringSync(),
      'generated contracts\n',
    );
  });

  for (final command in ['bootstrap', 'resolve-workspace']) {
    for (final dependency in dependencyCommands) {
      test('$command stops on $dependency failure', () async {
        fixture.environment['ADELE_TEST_FAIL_DEPENDENCY'] = dependency;
        final result = await fixture.invoke([command]);
        expect(result.exitCode, 19);
        expect(fixture.commands.readAsLinesSync(), [
          'pub-get',
          if (dependency == 'workspace-list') 'workspace-list',
        ]);
        expect(fixture.generationArguments.existsSync(), isFalse);
        expect(fixture.generatedContract.existsSync(), isFalse);
      });
    }
  }

  test(
    'resolve leaves missing output for the selected CI test to generate',
    () async {
      await resolveWorkspace();
      expect(fixture.generatedContract.existsSync(), isFalse);

      final result = await fixture.invoke([
        'test',
        '--target',
        'adele_tools',
        '--ci',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(fixture.commands.readAsLinesSync(), [
        ...dependencyCommands,
        'generate|path',
        'test|dart|${fixture.root.path}',
      ]);
      fixture.expectGenerationArguments();
      expect(
        fixture.generatedContract.readAsStringSync(),
        fixture.contractSource.readAsStringSync(),
      );
      expect(result.stdout, contains('==> START test: adele_tools'));
      expectNoNativeBuild();
    },
  );

  test(
    'resolve leaves stale output for analyze to refresh before every analyzer',
    () async {
      fixture.generatedContract.writeAsStringSync('stale contract');
      fixture.generatedContract.setLastModifiedSync(DateTime.utc(2000));
      final modified = fixture.generatedContract.lastModifiedSync();
      await resolveWorkspace();
      expect(fixture.generatedContract.readAsStringSync(), 'stale contract');
      expect(fixture.generatedContract.lastModifiedSync(), modified);

      const changedContract = 'changed since workspace resolution\n';
      fixture.contractSource.writeAsStringSync(changedContract);
      final result = await fixture.invoke(['analyze']);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(fixture.commands.readAsLinesSync(), [
        ...dependencyCommands,
        'generate|path',
        'analyze|dart|${fixture.root.path}',
        'analyze|dart|${fixture.root.path}',
        for (final target in tooling.analysisTargets)
          'analyze|${target.flutter ? 'flutter' : 'dart'}|${fixture.root.path}/${target.path}',
      ]);
      fixture.expectGenerationArguments();
      expect(fixture.generatedContract.readAsStringSync(), changedContract);
    },
  );

  test(
    'resolved interaction CI supplies CodeForge and runs only its directory',
    () async {
      await resolveWorkspace();
      final result = await fixture.invoke([
        'test',
        '--target',
        interactions,
        '--ci',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(fixture.commands.readAsLinesSync(), [
        ...dependencyCommands,
        'generate|path',
        'test|flutter|${fixture.root.path}/app',
      ]);
      expect(fixture.appTestInvocations(), [
        ['test', '--concurrency', '1', 'plugin_interactions_test'],
      ]);
    },
  );

  for (final shard in [1, 2]) {
    test(
      'interaction CI shard $shard/2 runs only its files with CodeForge',
      () async {
        final target = tooling.lookupTestTarget(interactions);
        final files = partitionTestFiles(
          Directory('${fixture.root.path}/app'),
          target.ciShards,
          testDirectory: target.testDirectory,
          costs: target.ciTestFileCosts,
        )[shard - 1];
        final result = await fixture.invoke([
          'test',
          '--target=$interactions',
          '--ci',
          '--shard=$shard',
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(fixture.commands.readAsLinesSync(), [
          'generate|path',
          'test|flutter|${fixture.root.path}/app',
        ]);
        expect(fixture.appTestInvocations(), [
          ['test', '--concurrency', '1', ...files],
        ]);
      },
    );
  }

  test(
    'ineligible desktop CI shard keeps selection and native loader without a scope',
    () async {
      final target = tooling.lookupTestTarget('adele_desktop');
      final app = Directory('${fixture.root.path}/${target.path}');
      for (var i = 0; i < target.ciShards; i++) {
        File(
          '${app.path}/${target.testDirectory}/nested/case_${i}_test.dart',
        ).createSync();
      }
      final shards = partitionTestFiles(
        app,
        target.ciShards,
        testDirectory: target.testDirectory,
        costs: target.ciTestFileCosts,
      );
      final result = await fixture.invoke([
        'test',
        '--target=${target.name}',
        '--ci',
        '--shard=${target.ciShards}',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, isNot(contains('git-test-aot scope:')));
      expect(fixture.commands.readAsLinesSync(), [
        'generate|path',
        'test|flutter|${app.path}',
      ]);
      expect(fixture.appTestInvocations(), [
        ['test', '--concurrency', '1', ...shards.last],
      ]);
    },
  );

  test('Diff frontend CI runs its package without building CodeForge', () async {
    final result = await fixture.invoke([
      'test',
      '--target=diff_viewer_frontend',
      '--ci',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(fixture.commands.readAsLinesSync(), [
      'generate|path',
      'test|flutter|${fixture.root.path}/plugins/diff_viewer/packages/frontend',
    ]);
    expectNoNativeBuild();
  });

  for (final ci in [false, true]) {
    test(
      'Git hosted tests run the whole package without CodeForge (ci=$ci)',
      () async {
        final result = await fixture.invoke([
          'test',
          '--target=$gitHosted',
          if (ci) '--ci',
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(fixture.commands.readAsLinesSync(), [
          'generate|path',
          'test|flutter|${fixture.root.path}/$gitHostedPath',
        ]);
        expect(fixture.gitHostedArguments.readAsLinesSync(), [
          'test',
          if (ci) ...['--concurrency', '1'],
        ]);
        expectNoNativeBuild();
      },
    );
  }

  for (final targetName in [
    'adele_tools',
    'adele_desktop',
    interactions,
    'adele_credential_store_native',
    null,
  ]) {
    test('test ${targetName ?? 'all'} generates once before workers', () async {
      final result = await fixture.invoke([
        'test',
        if (targetName != null) ...[
          '--target',
          targetName,
        ] else ...[
          '--jobs',
          '2',
        ],
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final targets = targetName == null
          ? tooling.testTargets
          : [tooling.lookupTestTarget(targetName)];
      final recorded = fixture.commands.readAsLinesSync();
      expect(recorded.first, 'generate|path');
      expect(
        recorded.skip(1),
        unorderedEquals([
          for (final target in targets)
            'test|${target.executable}|${fixture.root.path}${target.path == '.' ? '' : '/${target.path}'}'
                '${target.name == 'adele_credential_store_native' ? '|${target.arguments.join(' ')}' : ''}',
        ]),
      );
      expect(
        result.stdout
            .toString()
            .split('\n')
            .where((line) => line.startsWith('==> START test:')),
        unorderedEquals([
          for (final target in targets) '==> START test: ${target.name}',
        ]),
      );
      if (targetName == null) {
        expect(fixture.appTestInvocations(), unorderedEquals(wholeAppRuns));
      } else if (targetName == interactions) {
        expect(fixture.appTestInvocations(), [
          ['test', 'plugin_interactions_test'],
        ]);
      }
      fixture.expectGenerationArguments();
    });
  }

  test('test all propagates a simulated native credential failure', () async {
    fixture.environment['ADELE_TEST_FAIL_CREDENTIAL_NATIVE'] = '1';
    final result = await fixture.invoke(['test', '--jobs', '2']);
    expect(result.exitCode, 37, reason: '${result.stdout}\n${result.stderr}');
    expect(
      result.stderr,
      'FAILED TEST TARGETS:\n  adele_credential_store_native (exit 37)\n',
    );
    final recorded = fixture.commands.readAsLinesSync();
    expect(recorded.first, 'generate|path');
    expect(
      recorded.skip(1),
      unorderedEquals([
        for (final target in tooling.testTargets)
          'test|${target.executable}|${fixture.root.path}${target.path == '.' ? '' : '/${target.path}'}'
              '${target.name == 'adele_credential_store_native' ? '|${target.arguments.join(' ')}' : ''}',
      ]),
    );
    expect(
      result.stdout,
      contains(
        'TEST SUMMARY: total ${tooling.testTargets.length}, '
        'passed ${tooling.testTargets.length - 1}, failed 1,',
      ),
    );
    fixture.expectGenerationArguments();
  });

  for (final (name, failure, code) in [
    (interactions, 'ADELE_TEST_FAIL_INTERACTION', 36),
    (gitHosted, 'ADELE_TEST_FAIL_GIT_HOSTED', 38),
  ]) {
    test(
      'check runs both app categories and hosted Git, propagating a $name failure',
      () async {
        fixture.generatedContract.writeAsStringSync(
          fixture.contractSource.readAsStringSync(),
        );
        fixture.environment[failure] = '1';
        final result = await fixture.invoke(['check']);
        expect(
          result.exitCode,
          code,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stdout, contains('==> PASS test: adele_desktop ('));
        expect(result.stderr, 'FAILED TEST TARGETS:\n  $name (exit $code)\n');
        expect(fixture.appTestInvocations(), unorderedEquals(wholeAppRuns));
        expect(fixture.gitHostedArguments.readAsLinesSync(), ['test']);
      },
    );
  }

  for (final (arguments, code) in [
    (['tools/adele.dart', 'unexpected-native-command'], 99),
    (['tools/adele.dart', 'test-credential-store-native', '--unexpected'], 97),
  ]) {
    test('mock dart rejects ${arguments.join(' ')}', () async {
      final result = await Process.run(
        '${fixture.root.path}/bin/dart',
        arguments,
        workingDirectory: fixture.root.path,
        environment: fixture.environment,
      );
      expect(result.exitCode, code);
      expect(fixture.commands.existsSync(), isFalse);
      expect(fixture.generatedContract.existsSync(), isFalse);
    });
  }

  test(
    'generate materializes and --check verifies without rewriting',
    () async {
      final result = await fixture.invoke(['generate']);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(fixture.commands.readAsLinesSync(), ['generate|path']);
      fixture.expectGenerationArguments();
      expect(
        fixture.generatedContract.readAsStringSync(),
        'generated contracts\n',
      );
      fixture.generatedContract.setLastModifiedSync(DateTime.utc(2000));
      final modified = fixture.generatedContract.lastModifiedSync();

      final checked = await fixture.invoke(['generate', '--check']);
      expect(checked.exitCode, 0, reason: checked.stderr.toString());
      expect(fixture.commands.readAsLinesSync(), [
        'generate|path',
        'generate|path|--check',
      ]);
      fixture.expectGenerationArguments(['--check']);
      expect(
        fixture.generatedContract.readAsStringSync(),
        'generated contracts\n',
      );
      expect(fixture.generatedContract.lastModifiedSync(), modified);
    },
  );

  for (final command in [
    <String>['generate', '--check'],
    <String>['check'],
  ]) {
    for (final stale in [false, true]) {
      test(
        '${command.join(' ')} does not repair ${stale ? 'stale' : 'missing'} outputs',
        () async {
          if (stale) {
            fixture.generatedContract.writeAsStringSync('stale contract');
          }
          final result = await fixture.invoke(command);
          expect(result.exitCode, 31);
          expect(
            result.stderr,
            contains('contract outputs are missing or stale'),
          );
          expect(fixture.commands.readAsLinesSync(), ['generate|path|--check']);
          fixture.expectGenerationArguments(['--check']);
          if (stale) {
            expect(
              fixture.generatedContract.readAsStringSync(),
              'stale contract',
            );
          } else {
            expect(fixture.generatedContract.existsSync(), isFalse);
          }
        },
      );
    }
  }

  test(
    'clean-contracts forwards only --clean without generating first',
    () async {
      fixture.generatedContract.writeAsStringSync('stale contract');
      final result = await fixture.invoke(['clean-contracts']);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(fixture.commands.readAsLinesSync(), ['generate|path|--clean']);
      fixture.expectGenerationArguments(['--clean']);
      expect(fixture.generatedContract.existsSync(), isFalse);
    },
  );

  for (final target in ['macos', 'windows']) {
    for (final command in ['run', 'build']) {
      test('$command $target generates once on PATH before Flutter', () async {
        final result = await fixture.invoke([command, target]);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(fixture.commands.readAsLinesSync(), [
          'generate|path',
          'flutter-launch',
        ]);
        fixture.expectGenerationArguments();
        expect(fixture.launchArguments.readAsLinesSync(), [
          command,
          if (command == 'run') '-d',
          target,
          '--debug',
        ]);
      });
    }
  }

  for (final arguments in <List<String>>[
    ['bootstrap'],
    ['analyze'],
    ['test', '--target', 'adele_tools'],
    ['test', '--target', 'adele_desktop', '--ci'],
    ['test', '--jobs', '2'],
    ['run', 'linux'],
    ['build', 'linux'],
    ['run', 'macos'],
    ['build', 'windows'],
    ['smoke', 'linux'],
  ]) {
    final resolveFirst =
        arguments.first == 'analyze' || arguments.contains('--ci');
    test(
      '${resolveFirst ? 'resolve-workspace then ' : ''}${arguments.join(' ')} stops consumers on generation failure',
      () async {
        final incremental =
            arguments.contains('linux') && arguments.first != 'smoke';
        fixture.environment['ADELE_TEST_FAIL_GENERATION'] = '1';
        // Even retained output must not let consumers bypass failed generation.
        fixture.generatedContract.writeAsStringSync('retained contract');
        if (resolveFirst) await resolveWorkspace();
        if (arguments.first == 'smoke') {
          fixture.environment.addAll({
            'ADELE_DEVELOPMENT_REPOSITORY_ROOT': fixture.root.path,
            'ADELE_DEVELOPMENT_PLUGIN_DIRECTORY':
                '${fixture.root.path}/plugins/workspace_demo',
            'ADELE_DEVELOPMENT_DIRECTORY': '${fixture.root.path}/development',
          });
        }
        final result = await fixture.invoke(arguments);
        expect(result.exitCode, 29);
        expect(result.stdout, contains('contract generator output'));
        expect(result.stderr, contains('contract generator failed'));
        expect(
          result.stderr,
          contains('contract-generation failed with exit code 29'),
        );
        expect(fixture.commands.readAsLinesSync(), [
          if (arguments.first == 'bootstrap' || resolveFirst)
            ...dependencyCommands,
          if (arguments.contains('linux')) 'inspect-sdk',
          if (incremental) ...toolCompilationEvents,
          incremental ? 'generate|aot|--incremental' : 'generate|path',
        ]);
        fixture.expectGenerationArguments([
          if (incremental) '--incremental',
        ], incremental);
        expect(result.stdout, isNot(contains('START test:')));
        if (resolveFirst) expectNoNativeBuild();
        expect(
          fixture.generatedContract.readAsStringSync(),
          'retained contract',
        );
        expect(fixture.launchArguments.existsSync(), isFalse);
        expect(fixture.frontendArguments.existsSync(), isFalse);
        fixture.expectNoPublishedInstallations();
      },
    );
  }

  test('generation failure retains structured process diagnostics', () async {
    final dart = File('${fixture.root.path}/bin/failing-dart');
    writeExecutableScript(dart, '''
printf 'generator stdout'
printf 'generator stderr' >&2
exit 27
''');
    try {
      await runContractCodegen(
        repositoryRoot: fixture.root,
        dartExecutable: dart.path,
        options: ['--check'],
      );
      fail('Expected generation to fail.');
    } on PluginBuildFailure catch (failure) {
      expect(
        failure.message,
        contains('contract-generation failed with exit code 27'),
      );
      final diagnostic = failure.diagnostic!;
      expect(diagnostic.stage, 'contract-generation');
      expect(diagnostic.command, [
        dart.path,
        'run',
        codegenEntrypoint,
        '--check',
      ]);
      expect(diagnostic.workingDirectory, fixture.root.path);
      expect(diagnostic.exitCode, 27);
      expect(diagnostic.stdoutText, 'generator stdout');
      expect(diagnostic.stderrText, 'generator stderr');
    }
  });

  test('generation process start failure is a PluginBuildFailure', () async {
    await expectLater(
      runContractCodegen(
        repositoryRoot: fixture.root,
        dartExecutable: '${fixture.root.path}/missing-dart',
      ),
      throwsA(
        isA<PluginBuildFailure>().having(
          (failure) => failure.message,
          'message',
          contains('contract-generation could not start'),
        ),
      ),
    );
    expect(fixture.commands.existsSync(), isFalse);
  });

  test(
    'Linux smoke builds the tool entrypoint and runs the matching bundle',
    () async {
      final developmentEnvironment = <String, String>{
        'ADELE_DEVELOPMENT_REPOSITORY_ROOT': fixture.root.path,
        'ADELE_DEVELOPMENT_PLUGIN_DIRECTORY':
            '${fixture.root.path}/plugins/workspace_demo',
        'ADELE_DEVELOPMENT_DIRECTORY': '${fixture.root.path}/development',
      };
      fixture.environment.addAll(developmentEnvironment);
      for (final (flag, mode) in [
        (null, 'profile'),
        ('--debug', 'profile'),
        ('--profile', 'profile'),
        ('--release', 'release'),
      ]) {
        final executable = File(
          '${fixture.root.path}/app/build/linux/x64/$mode/bundle/adele_desktop',
        );
        executable.parent.createSync(recursive: true);
        writeExecutableScript(executable, '''
test "\$PWD" = '${fixture.root.path}' || exit 98
test "\$#" = 0 || exit 97
printf 'smoke-runtime|$mode\n' >> '${fixture.commands.path}'
''');
        final result = await fixture.invoke(['smoke', 'linux', ?flag]);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(fixture.commands.readAsLinesSync(), [
          'inspect-sdk',
          'generate|path',
          'flutter-launch',
          'smoke-runtime|$mode',
        ]);
        fixture.expectGenerationArguments();
        expect(fixture.launchArguments.readAsLinesSync(), [
          'build',
          'linux',
          '--$mode',
          '--target=tool/development_runtime_smoke/main.dart',
          for (final entry in developmentEnvironment.entries)
            '--dart-define=${entry.key}=${entry.value}',
          '--dart-define=ADELE_DEVELOPMENT_DART_EXECUTABLE=${fixture.root.path}/bin/dart',
          '--dart-define=ADELE_DEVELOPMENT_DARTAOTRUNTIME_EXECUTABLE=${fixture.sdkBin.path}/dartaotruntime',
          '--dart-define=ADELE_DEVELOPMENT_FLUTTER_EXECUTABLE=${fixture.root.path}/bin/flutter',
        ]);
        fixture.commands.deleteSync();
      }
    },
  );

  for (final arguments in [
    ['run', 'linux', '--profile'],
    ['run', 'linux', '--release'],
    ['build', 'linux', '--release'],
  ]) {
    test(
      '${arguments.join(' ')} selects the ordinary app entrypoint',
      () async {
        final result = await fixture.invoke(arguments);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        final run = arguments.first == 'run';
        expect(fixture.launchArguments.readAsLinesSync().take(run ? 5 : 4), [
          arguments.first,
          if (run) '-d',
          'linux',
          arguments.last,
          '--target=lib/main.dart',
        ]);
        expect(
          fixture.commands.readAsLinesSync(),
          contains('compiled|$sessionEvaluatorEntrypoint'),
        );
      },
    );
  }

  test('missing matched runtime fails before compiling or launching', () async {
    File('${fixture.sdkBin.path}/dartaotruntime').deleteSync();
    final ProcessResult result = await fixture.invoke(<String>['run', 'linux']);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('Required SDK executable is missing'));
    expect(fixture.commands.readAsLinesSync(), <String>['inspect-sdk']);
    expect(fixture.launchArguments.existsSync(), isFalse);
    fixture.expectNoPublishedInstallations();
  });
}
