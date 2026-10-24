import 'dart:io';

void reportBuildTiming(
  String stage,
  Stopwatch timer, [
  String status = 'done',
]) {
  final milliseconds = timer.elapsedMilliseconds;
  final elapsed = milliseconds < 1000
      ? '${milliseconds}ms'
      : '${(milliseconds / 1000).toStringAsFixed(1)}s';
  stdout.writeln('==> $stage [$status, $elapsed]');
}

Future<T> timeBuildStage<T>(String stage, Future<T> Function() action) async {
  final timer = Stopwatch()..start();
  var status = 'failed';
  try {
    final value = await action();
    status = 'done';
    return value;
  } finally {
    reportBuildTiming(stage, timer, status);
  }
}
