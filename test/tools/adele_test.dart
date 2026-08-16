import 'dart:async';

import 'package:test/test.dart';

import '../../tools/adele.dart';
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

  test('target data preserves package-specific runners and timeouts', () {
    expect(
      <String>[
        for (final TestTarget target in testTargets)
          '${target.name}|${target.executable}|${target.path}|'
              '${target.arguments.join(' ')}',
      ],
      const <String>[
        'adele_tools|dart|.|test test/tools',
        'adele_contract|dart|packages/contract|test',
        'contract_codegen|dart|packages/contract_codegen|test',
        'adele_plugin_api|dart|packages/plugin_api|test',
        'adele_model_provider|dart|packages/model_provider|test',
        'adele_capabilities|dart|packages/capabilities|test',
        'agent_kernel|dart|packages/agent_kernel|test',
        'plugin_builder|dart|packages/plugin_builder|test',
        'plugin_runtime|dart|packages/plugin_runtime|test --timeout 10s',
        'plugin_backend_host|dart|packages/plugin_backend_host|test',
        'resource_inspector_contract|dart|plugins/resource_inspector/packages/contract|test --timeout 4m',
        'scripted_model_contract|dart|plugins/scripted_model/packages/contract|test --timeout 4m',
        'scripted_model_backend|dart|plugins/scripted_model/packages/backend|test',
        'openai_model_provider_backend|dart|plugins/openai/packages/backend|test',
        'workspace_demo_contract|dart|plugins/workspace_demo/packages/contract|test',
        'workspace_demo_backend|dart|plugins/workspace_demo/packages/backend|test',
        'adele_desktop|flutter|app|test',
      ],
    );
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
