import 'dart:math' as math;

final class TestTarget {
  const TestTarget({
    required this.name,
    required this.path,
    required this.executable,
    required this.arguments,
    this.testConcurrency,
    this.ciTestConcurrency,
    this.linuxDesktopDeps = false,
  });

  final List<String> arguments;
  final int? ciTestConcurrency;
  final String executable;
  final bool linuxDesktopDeps;
  final String name;
  final String path;
  final int? testConcurrency;

  List<String> argumentsFor({bool ci = false}) {
    final int? concurrency = ci
        ? ciTestConcurrency ?? testConcurrency
        : testConcurrency;
    return <String>[
      ...arguments,
      if (concurrency != null) ...<String>['--concurrency', '$concurrency'],
    ];
  }
}

final class TestTargetResult {
  const TestTargetResult({
    required this.target,
    required this.exitCode,
    required this.elapsed,
    this.error,
  });

  final Duration elapsed;
  final Object? error;
  final int exitCode;
  final TestTarget target;

  bool get passed => exitCode == 0;
}

final class TestRunSummary {
  const TestRunSummary({required this.results, required this.elapsed});

  final Duration elapsed;
  final List<TestTargetResult> results;

  List<TestTargetResult> get failures => <TestTargetResult>[
    for (final TestTargetResult result in results)
      if (!result.passed) result,
  ];

  int get passed => results.length - failures.length;

  bool get succeeded => failures.isEmpty;
}

typedef TestTargetExecutor = Future<int> Function(TestTarget target);
typedef TestTargetCallback = void Function(TestTarget target);
typedef TestResultCallback = void Function(TestTargetResult result);

Future<TestRunSummary> runTestTargets({
  required List<TestTarget> targets,
  required int jobs,
  required TestTargetExecutor execute,
  TestTargetCallback? onStart,
  TestResultCallback? onComplete,
}) async {
  if (jobs < 1) {
    throw ArgumentError.value(jobs, 'jobs', 'must be a positive integer');
  }

  final Stopwatch total = Stopwatch()..start();
  final List<TestTargetResult?> results = List<TestTargetResult?>.filled(
    targets.length,
    null,
  );
  int nextTarget = 0;

  Future<void> worker() async {
    while (nextTarget < targets.length) {
      final int index = nextTarget++;
      final TestTarget target = targets[index];
      onStart?.call(target);
      final Stopwatch elapsed = Stopwatch()..start();
      int targetExitCode;
      Object? error;
      try {
        targetExitCode = await execute(target);
      } on Object catch (caught) {
        targetExitCode = 1;
        error = caught;
      }
      elapsed.stop();
      final TestTargetResult result = TestTargetResult(
        target: target,
        exitCode: targetExitCode,
        elapsed: elapsed.elapsed,
        error: error,
      );
      results[index] = result;
      onComplete?.call(result);
    }
  }

  await Future.wait(<Future<void>>[
    for (int index = 0; index < math.min(jobs, targets.length); index++)
      worker(),
  ]);
  total.stop();
  return TestRunSummary(
    results: <TestTargetResult>[
      for (final TestTargetResult? result in results) result!,
    ],
    elapsed: total.elapsed,
  );
}

String formatTestDuration(Duration duration) {
  if (duration.inSeconds < 1) return '${duration.inMilliseconds}ms';
  final int minutes = duration.inMinutes;
  final int seconds = duration.inSeconds.remainder(60);
  return minutes == 0 ? '${seconds}s' : '${minutes}m ${seconds}s';
}
