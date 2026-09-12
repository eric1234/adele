/// Attempts every action in order, then rethrows the first error with its stack.
Future<void> closeResources(List<Future<void> Function()> actions) async {
  Object? firstError;
  StackTrace? firstStackTrace;
  for (final Future<void> Function() action in actions) {
    try {
      await action();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
}
