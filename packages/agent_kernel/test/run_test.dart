import 'dart:async';

import 'package:adele_orchestration/adele_orchestration.dart' as orchestration;
import 'package:adele_product/adele_product.dart' as product;
import 'package:agent_kernel/agent_kernel.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  test('model invocation identity is the public orchestration identity', () {
    final orchestration.ModelInvocationId id = ModelInvocationId('model-1');
    expect(id, orchestration.ModelInvocationId('model-1'));
  });

  test('journal invalidation is async, coalesced and detachable', () async {
    final AgentRun run = AgentRun(id: RunId('live'), sessionId: SessionId('s'));
    int notifications = 0;
    final StreamSubscription<void> subscription = run.journal.changes.listen((
      _,
    ) {
      notifications++;
      expect(run.state, RunState.running);
      expect(run.journal.lastSequence, 2);
      expect(run.journal.recordsAfter(1).single.sequence, 2);
    });
    run.start();
    final ExecutionEventRecord recorded = run.record(
      ModelInvocationStarted(ModelInvocationId('m')),
    );
    expect(recorded.sequence, 2);
    expect(run.journal.records.last, same(recorded));
    expect(notifications, 0);
    await Future<void>.delayed(Duration.zero);
    expect(notifications, 1);
    await subscription.cancel();
    run.complete();
    await Future<void>.delayed(Duration.zero);
    expect(notifications, 1);
    expect(run.journal.lastSequence, 3);
    expect(run.journal.recordsAfter(2).single.event, isA<RunCompleted>());
    expect(() => run.journal.recordsAfter(0).clear(), throwsUnsupportedError);
  });

  test(
    'observer errors and reentrant reads never enter Run recording',
    () async {
      final AgentRun run = AgentRun(
        id: RunId('observed'),
        sessionId: SessionId('s'),
      );
      final Object observerError = StateError('observer only');
      final List<Object> errors = [];
      late StreamSubscription<void> broken;
      runZonedGuarded(() {
        broken = run.journal.changes.listen((_) {
          expect(run.journal.records.last.event, isA<RunCompleted>());
          throw observerError;
        });
      }, (Object error, StackTrace stack) => errors.add(error));
      int healthy = 0;
      final StreamSubscription<void> subscription = run.journal.changes.listen((
        _,
      ) {
        healthy++;
        expect(() => run.start(), throwsA(isA<InvalidRunOperation>()));
      });
      run.start();
      run.complete();
      await Future<void>.delayed(Duration.zero);
      expect(errors, [same(observerError)]);
      expect(healthy, 1);
      expect(run.failure, isNull);
      expect(run.state, RunState.completed);
      expect(run.journal.records.map((r) => r.sequence), [1, 2]);
      await broken.cancel();
      await subscription.cancel();
    },
  );

  test('kernel re-exports the canonical product Session identity', () {
    final product.SessionId sessionId = SessionId('canonical-session');

    expect(sessionId, SessionId('canonical-session'));
  });

  test('Run enforces its small top-level lifecycle', () {
    final AgentRun completed = AgentRun(
      id: RunId('run-completed'),
      sessionId: SessionId('session-1'),
    );
    expect(completed.state, RunState.created);
    completed.start();
    expect(completed.state, RunState.running);
    completed.record(ModelInvocationStarted(ModelInvocationId('model-1')));
    expect(completed.state, RunState.running);
    completed.complete();
    expect(completed.state, RunState.completed);
    expect(() => completed.start(), throwsA(isA<InvalidRunOperation>()));
    expect(() => completed.cancel(), throwsA(isA<InvalidRunOperation>()));

    final AgentRun failed = AgentRun(
      id: RunId('run-failed'),
      sessionId: SessionId('session-1'),
    )..start();
    final StateError error = StateError('model failed');
    failed.fail(error);
    expect(failed.state, RunState.failed);
    expect(failed.failure, same(error));
    expect(() => failed.complete(), throwsA(isA<InvalidRunOperation>()));

    final AgentRun cancelled = AgentRun(
      id: RunId('run-cancelled'),
      sessionId: SessionId('session-1'),
    )..cancel();
    expect(cancelled.state, RunState.cancelled);
  });

  test('interruption waiting and exact resolution are correlated', () async {
    final TestExecutable executable = TestExecutable();
    final ToolInvocation invocation = await testInvocation(executable);
    final EffectDescription effects = await executable.describe(
      invocation.arguments,
      testExecutionContext(),
    );
    final ToolApprovalInterruption interruption = ToolApprovalInterruption(
      id: RunInterruptionId('approval-1'),
      invocation: invocation,
      effects: effects,
    );
    final AgentRun run = AgentRun(
      id: RunId('run-1'),
      sessionId: SessionId('session-1'),
    )..start();

    run.interrupt(interruption);
    expect(run.state, RunState.waiting);
    expect(run.interruptions[interruption.id], same(interruption));
    expect(
      () => run.resolveInterruption(
        ToolApprovalResolution(
          interruptionId: interruption.id,
          toolInvocationId: ToolInvocationId('different-tool'),
          approved: true,
        ),
      ),
      throwsA(isA<InvalidRunOperation>()),
    );
    expect(run.state, RunState.waiting);

    final ResolvedRunInterruption resolved = run.resolveInterruption(
      ToolApprovalResolution(
        interruptionId: interruption.id,
        toolInvocationId: invocation.id,
        approved: true,
      ),
    );
    expect(resolved.interruption, same(interruption));
    expect(run.state, RunState.running);
    expect(run.interruptions, isEmpty);
  });

  test('journal records typed events in deterministic monotonic order', () {
    final AgentRun run = AgentRun(
      id: RunId('run-1'),
      sessionId: SessionId('session-1'),
    )..start();
    run.record(ModelInvocationStarted(ModelInvocationId('model-1')));
    run.record(
      ModelInvocationSettled(
        invocationId: ModelInvocationId('model-1'),
        settlement: ModelSettlement.completed,
        incompleteReason: null,
        metadata: ModelTerminalMetadata(),
      ),
    );
    expect(
      () => run.record(const RunCompleted()),
      throwsA(isA<InvalidRunOperation>()),
    );
    run.complete();

    expect(
      run.journal.records.map((ExecutionEventRecord record) => record.sequence),
      <int>[1, 2, 3, 4],
    );
    expect(
      run.journal.records.map((ExecutionEventRecord record) => record.event),
      <Matcher>[
        isA<RunStarted>(),
        isA<ModelInvocationStarted>(),
        isA<ModelInvocationSettled>(),
        isA<RunCompleted>(),
      ],
    );
    expect(
      () => run.journal.records.add(
        const ExecutionEventRecord(sequence: 5, event: RunCompleted()),
      ),
      throwsUnsupportedError,
    );
  });

  test('model settlement journal events enforce incomplete reasons', () {
    final ModelInvocationId id = ModelInvocationId('model-settlement');
    final ModelTerminalMetadata metadata = ModelTerminalMetadata();
    for (final ({ModelSettlement settlement, ModelIncompleteReason? reason})
        valid
        in <({ModelSettlement settlement, ModelIncompleteReason? reason})>[
          (settlement: ModelSettlement.completed, reason: null),
          (settlement: ModelSettlement.refused, reason: null),
          (
            settlement: ModelSettlement.incomplete,
            reason: ModelIncompleteReason.outputLimit,
          ),
        ]) {
      expect(
        ModelInvocationSettled(
          invocationId: id,
          settlement: valid.settlement,
          incompleteReason: valid.reason,
          metadata: metadata,
        ),
        isA<ModelInvocationSettled>(),
      );
    }
    for (final ({ModelSettlement settlement, ModelIncompleteReason? reason})
        invalid
        in <({ModelSettlement settlement, ModelIncompleteReason? reason})>[
          (
            settlement: ModelSettlement.completed,
            reason: ModelIncompleteReason.outputLimit,
          ),
          (
            settlement: ModelSettlement.refused,
            reason: ModelIncompleteReason.contextLimit,
          ),
          (settlement: ModelSettlement.incomplete, reason: null),
        ]) {
      expect(
        () => ModelInvocationSettled(
          invocationId: id,
          settlement: invalid.settlement,
          incompleteReason: invalid.reason,
          metadata: metadata,
        ),
        throwsFormatException,
      );
    }
  });

  test(
    'Run remains waiting until every outstanding interruption resolves',
    () async {
      final TestExecutable executable = TestExecutable();
      final ToolInvocation first = await testInvocation(
        executable,
        invocationId: 'tool-1',
      );
      final ToolInvocation second = await testInvocation(
        executable,
        invocationId: 'tool-2',
      );
      final EffectDescription effects = await executable.describe(
        first.arguments,
        first.context,
      );
      final ToolApprovalInterruption firstApproval = ToolApprovalInterruption(
        id: RunInterruptionId('approval-1'),
        invocation: first,
        effects: effects,
      );
      final ToolApprovalInterruption secondApproval = ToolApprovalInterruption(
        id: RunInterruptionId('approval-2'),
        invocation: second,
        effects: effects,
      );
      final AgentRun run = AgentRun(
        id: RunId('run-1'),
        sessionId: SessionId('session-1'),
      )..start();

      run
        ..interrupt(firstApproval)
        ..interrupt(secondApproval);
      run.resolveInterruption(
        ToolApprovalResolution(
          interruptionId: firstApproval.id,
          toolInvocationId: first.id,
          approved: false,
        ),
      );
      expect(run.state, RunState.waiting);
      expect(run.interruptions.keys, <RunInterruptionId>[secondApproval.id]);

      run.resolveInterruption(
        ToolApprovalResolution(
          interruptionId: secondApproval.id,
          toolInvocationId: second.id,
          approved: true,
        ),
      );
      expect(run.state, RunState.running);
    },
  );

  test('Run rejects a tool interruption owned by another Run', () async {
    final TestExecutable executable = TestExecutable();
    final ToolInvocation invocation = await testInvocation(executable);
    final EffectDescription effects = await executable.describe(
      invocation.arguments,
      invocation.context,
    );
    final AgentRun otherRun = AgentRun(
      id: RunId('run-other'),
      sessionId: SessionId('session-1'),
    )..start();

    expect(
      () => otherRun.interrupt(
        ToolApprovalInterruption(
          id: RunInterruptionId('approval-1'),
          invocation: invocation,
          effects: effects,
        ),
      ),
      throwsA(isA<InvalidRunOperation>()),
    );
    expect(otherRun.state, RunState.running);
    expect(otherRun.interruptions, isEmpty);
  });
}
