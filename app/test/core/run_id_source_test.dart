import 'package:adele_desktop/core/run_id_source.dart';
import 'package:agent_kernel/agent_kernel.dart' show RunId;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('seeded Run IDs are deterministic, monotonic and distinct', () {
    final RunIdSource ids = MonotonicRunIdSource(seed: 'chat-test');
    final List<RunId> allocated = List<RunId>.generate(
      12,
      (_) => ids.nextRunId(),
    );

    expect(allocated, <RunId>[
      for (int index = 1; index <= 12; index++) RunId('run-chat-test-$index'),
    ]);
    expect(allocated.toSet(), hasLength(12));
  });

  test('independent explicit seeds retain independent counters', () {
    final RunIdSource first = MonotonicRunIdSource(seed: 'first-window');
    final RunIdSource second = MonotonicRunIdSource(seed: 'second-window');

    expect(first.nextRunId(), RunId('run-first-window-1'));
    expect(first.nextRunId(), RunId('run-first-window-2'));
    expect(second.nextRunId(), RunId('run-second-window-1'));
    expect(first.nextRunId(), RunId('run-first-window-3'));
    expect(second.nextRunId(), RunId('run-second-window-2'));
  });
}
