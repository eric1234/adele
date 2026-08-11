import 'package:agent_kernel/agent_kernel.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
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
    final ToolInvocation invocation = testInvocation(executable);
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
    run.record(ModelInvocationCompleted(ModelInvocationId('model-1')));
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
        isA<ModelInvocationCompleted>(),
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

  test(
    'Run remains waiting until every outstanding interruption resolves',
    () async {
      final TestExecutable executable = TestExecutable();
      final ToolInvocation first = testInvocation(
        executable,
        invocationId: 'tool-1',
      );
      final ToolInvocation second = testInvocation(
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
    final ToolInvocation invocation = testInvocation(executable);
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
