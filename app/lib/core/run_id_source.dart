import 'package:agent_kernel/agent_kernel.dart' show RunId;

abstract interface class RunIdSource {
  RunId nextRunId();
}

/// Application-local allocation, independent of product identity persistence.
final class MonotonicRunIdSource implements RunIdSource {
  MonotonicRunIdSource({String? seed})
    : _seed = seed ?? DateTime.now().microsecondsSinceEpoch.toString();

  final String _seed;
  int _next = 1;

  @override
  RunId nextRunId() => RunId('run-$_seed-${_next++}');
}
