import 'dart:async';
import 'dart:convert';

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
            target.name: target.name == 'contract_codegen' ? 4 : null,
        },
      );
    });
  });

  group('target lookup', () {
    test('returns the exact target', () {
      expect(lookupTestTarget('contract_codegen').name, 'contract_codegen');
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
