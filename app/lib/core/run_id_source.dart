import 'package:adele_product/adele_product.dart' show RunId;

abstract interface class RunIdSource {
  RunId nextRunId();
}

/// Runtime-owned seeded allocation; no persisted counter or restore allocation.
final class MonotonicRunIdSource implements RunIdSource {
  MonotonicRunIdSource({String? seed})
    : _seed = seed ?? DateTime.now().microsecondsSinceEpoch.toString();

  final String _seed;
  int _next = 1;

  @override
  RunId nextRunId() => RunId('run-$_seed-${_next++}');
}
