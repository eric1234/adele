import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/run_id_source.dart';
import 'package:adele_desktop/ui/execution/session_execution_controller.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

final _projectProvider = ProviderId('dev.adele.test.project');
final _environmentProvider = ProviderId('dev.adele.test.environment');
final _strategy = OrchestrationStrategyId('dev.adele.test.strategy');

void main() {
  late Directory source;
  late AdeleRuntime runtime;
  late Session session;
  late Database inspection;
  late _ProviderChannel channel;
  late _Model model;
  late _Tool tool;
  late _Execution execution;
  late int materializations;

  setUp(() async {
    source = Directory.systemTemp.createTempSync('adele-durable-run-');
    addTearDown(() => source.deleteSync(recursive: true));
    runtime = AdeleRuntime(
      ids: MonotonicProductIdSource(seed: 'durable-run'),
      runIds: MonotonicRunIdSource(seed: 'durable-run'),
    );
    addTearDown(runtime.close);
    channel = _ProviderChannel();
    _registerProviders(runtime, channel, environment: true);
    materializations = 0;
    final registration = runtime.extensions.register(
      point: orchestrationStrategyContributions,
      id: ExtensionId('dev.adele.test.strategy'),
      value: OrchestrationStrategyContribution(
        strategyId: _strategy,
        materialize: (context) {
          materializations++;
          return execution = _Execution(context.host);
        },
      ),
    );
    addTearDown(registration.close);
    session = await _createSession(runtime, source);
    expect(materializations, 0);
    inspection = sqlite3.open('${source.path}/.adele/data.db');
    addTearDown(inspection.close);
    model = _Model();
    tool = _Tool();
  });

  Future<SessionOrchestrationRun> createRun({
    ToolPolicyDecision decision = ToolPolicyDecision.allow,
    Matcher? expectedCloseFailure,
  }) async {
    final run = await createSessionOrchestrationRun(
      lifecycle: runtime.lifecycle,
      sessionId: session.id,
      runId: runtime.runIds.nextRunId(),
      contextComposer: runtime.contextComposer,
      model: model,
      toolCatalog: _catalog(tool),
      policy: _Policy(decision),
    );
    addTearDown(
      () => expectedCloseFailure == null
          ? run.close()
          : expectLater(run.close(), throwsA(expectedCloseFailure)),
    );
    expect(run.run.id, RunId('run-durable-run-1'));
    expect(run.run.state, RunState.created);
    expect(run.run.journal.records, isEmpty);
    expect(materializations, 1);
    expect(model.calls, 0);
    expect(tool.executions, 0);
    expect(runtime.store.runRecord(run.run.id), isNull);
    expect(runtime.lifecycle.runActivity(run.run.id), isNull);
    expect(runtime.store.runsForSession(session.id), isEmpty);
    expect(_runRows(inspection), isEmpty);
    return run;
  }

  void expectRetained(
    AdeleRuntime owner,
    SessionOrchestrationRun run,
    RunTerminalState state,
  ) {
    final record = owner.store.runRecord(run.run.id)!;
    expect(record.id, run.run.id);
    expect(record.sessionId, session.id);
    expect(record.state, state);
    final activity = owner.lifecycle.runActivity(run.run.id)!;
    _expectActivity(activity, run.activity.snapshot);
    expect(owner.store.runsForSession(session.id), [same(record)]);
    expect(_runRows(inspection), [
      {
        'id': run.run.id.value,
        'session_id': session.id.value,
        'terminal_state': state.name,
      },
    ]);
  }

  Future<AdeleRuntime> reopen(
    SessionOrchestrationRun run, {
    RunActivitySnapshot? expectedRecovered,
  }) async {
    await runtime.close();
    final ids = _NoAllocationIds();
    final fresh = AdeleRuntime(ids: ids, runIds: ids);
    addTearDown(fresh.close);
    expect(fresh.runIds, same(ids));
    expect(fresh.store, isNot(same(runtime.store)));
    expect(fresh.store.runRecord(run.run.id), isNull);
    expect(fresh.store.runsForSession(session.id), isEmpty);
    final freshChannel = _ProviderChannel();
    _registerProviders(fresh, freshChannel);
    expect(fresh.registry.providersFor(environmentProviderCapability), isEmpty);
    expect(
      fresh.extensions.discover(orchestrationStrategyContributions),
      isEmpty,
    );
    final calls = (
      materializations,
      execution.startCalls,
      execution.approvalCalls,
      execution.closeCalls,
      model.calls,
      tool.executions,
      channel.environmentCalls,
    );
    final rows = _runRows(inspection);
    final task = runtime.store.task(session.taskId)!;
    final project = await fresh.lifecycle.openProject(
      sourceLocation: source.uri,
      provider: fresh.lifecycle.resolveProjectProvider(_projectProvider),
    );
    expect(project.id, task.projectId);
    final restored = fresh.store.session(session.id)!;
    expect(restored, isNot(same(session)));
    expect(restored.taskId, session.taskId);
    expect(restored.strategyId, _strategy);
    expect(fresh.lifecycle.hasSessionExecution(restored), isFalse);
    final authority = fresh.store.requireSessionAuthority(session.id);
    expect(
      authority.environmentId,
      runtime.store.requireSessionAuthority(session.id).environmentId,
    );
    expect(
      fresh.lifecycle.environmentRuntime.currentMaterialization(
        authority.environmentId,
      ),
      isNull,
    );
    expect(
      () => fresh.lifecycle.resolveSessionStrategy(session.id),
      throwsA(isA<OrchestrationStrategyUnavailable>()),
    );
    final controller = SessionExecutionController(
      runtime: fresh,
      session: restored,
      providerId: ProviderId('dev.adele.test.absent-model'),
      model: 'deterministic',
    );
    addTearDown(controller.close);
    expect(controller.currentRun, isNull);
    expect(controller.activeRunFuture, isNull);
    expect(controller.isRunning, isFalse);
    expect(controller.isAdvancing, isFalse);
    expect(controller.pendingApproval, isNull);
    final retained = fresh.lifecycle.runActivity(run.run.id);
    expect(controller.activityForRun(run.run.id), same(retained));
    expect(controller.stateForRun(run.run.id), retained?.state);
    if (retained != null) {
      _expectActivity(retained, run.activity.snapshot);
      expect(retained, isNot(same(run.activity.snapshot)));
    }
    final recovered = fresh.lifecycle.recoveredRun(run.run.id);
    if (retained != null || expectedRecovered != null) {
      expect(recovered, isNotNull);
    }
    if (recovered != null) {
      expect(recovered.session, same(restored));
      expect(recovered.runId, run.run.id);
      expect(recovered.terminalRecord, same(fresh.store.runRecord(run.run.id)));
      expect(
        recovered.status,
        retained == null
            ? RecoveredRunStatus.interrupted
            : RecoveredRunStatus.terminal,
      );
      _expectActivity(
        recovered.activity,
        expectedRecovered ?? run.activity.snapshot,
      );
      final scoped = fresh.lifecycle.recoveredRunsForSession(session.id);
      expect(scoped, [same(recovered)]);
      expect(() => scoped.clear(), throwsUnsupportedError);
    }
    expect(fresh.lifecycle.recoveredRun(RunId('unknown')), isNull);
    expect(
      fresh.lifecycle.recoveredRunsForSession(SessionId('unknown')),
      isEmpty,
    );
    expect(fresh.plugins.host, isNull);
    expect(fresh.plugins.backends, isEmpty);
    expect(ids.calls, 0);
    expect(freshChannel.projectCalls, 1);
    expect(freshChannel.environmentCalls, 0);
    expect((
      materializations,
      execution.startCalls,
      execution.approvalCalls,
      execution.closeCalls,
      model.calls,
      tool.executions,
      channel.environmentCalls,
    ), calls);
    expect(_runRows(inspection), rows);
    return fresh;
  }

  for (final failed in [false, true]) {
    test('actual ${failed ? 'failed' : 'completed'} Run survives fresh runtime '
        'with immutable activity but no execution', () async {
      final run = await createRun();
      final primary = ModelFailure(
        kind: ModelFailureKind.providerFailure,
        providerCode: 'fixture_failure',
        providerMessage: 'Strategy failed after tool settlement.',
        providerDetails: {'retryable': false},
        cause: StateError('private exception must not survive'),
      );
      if (failed) execution.failure = primary;
      if (failed) {
        await expectLater(run.start(), throwsA(same(primary)));
      } else {
        await run.start();
      }
      expect(run.run.state, failed ? RunState.failed : RunState.completed);
      expect(run.run.failure, failed ? same(primary) : isNull);
      expect(model.calls, 1);
      expect(tool.executions, 1);
      expect(execution.closeCalls, 1);
      final events = run.run.journal.records.map((record) => record.event);
      expect(events.whereType<ModelInvocationSettled>(), hasLength(1));
      expect(events.whereType<ToolExecutionCompleted>(), hasLength(1));
      expect(events.last, failed ? isA<RunFailed>() : isA<RunCompleted>());
      final state = failed
          ? RunTerminalState.failed
          : RunTerminalState.completed;
      expectRetained(runtime, run, state);
      final record = runtime.store.runRecord(run.run.id)!;
      final activity = runtime.lifecycle.runActivity(run.run.id)!;
      // The omitted text delta retains its gap rather than dense renumbering.
      expect(activity.models.single.startSequence, 2);
      expect(activity.models.single.outputs.map((output) => output.sequence), [
        4,
        5,
        6,
      ]);
      final evidence = run.run.journal.records;
      // A second INSERT during explicit close must not be attempted.
      _rejectRunInsert(inspection);
      await run.close();
      await run.close();
      expect(execution.closeCalls, 1);
      expect(run.run.journal.records, orderedEquals(evidence));
      final fresh = await reopen(run);
      expectRetained(fresh, run, state);
      expect(fresh.store.runRecord(run.run.id), isNot(same(record)));
      expect(
        fresh.lifecycle
            .runActivity(run.run.id)!
            .models
            .single
            .outputs
            .map((output) => output.sequence),
        [4, 5, 6],
      );
    });
  }

  for (final waiting in [false, true]) {
    test('close preserves ${waiting ? 'waiting approval' : 'unstarted Run'} '
        'without inventing a durable record on reopen', () async {
      final run = await createRun(decision: ToolPolicyDecision.ask);
      if (waiting) await run.start();
      final state = waiting ? RunState.waiting : RunState.created;
      expect(run.run.state, state);
      expect(run.run.interruptions, waiting ? hasLength(1) : isEmpty);
      expect(runtime.store.runRecord(run.run.id), isNull);
      expect(runtime.store.runsForSession(session.id), isEmpty);
      expect(_runRows(inspection), isEmpty);
      final evidence = run.run.journal.records;
      final interruptions = Map.of(run.run.interruptions);
      _rejectRunInsert(inspection);
      await run.close();
      expect(run.run.state, state);
      expect(run.run.failure, isNull);
      expect(run.run.journal.records, orderedEquals(evidence));
      expect(run.run.interruptions, interruptions);
      expect(execution.closeCalls, 1);
      expect(execution.approvalCalls, 0);
      expect(model.calls, waiting ? 1 : 0);
      expect(tool.executions, 0);
      final fresh = await reopen(run);
      expect(fresh.store.runRecord(run.run.id), isNull);
      expect(fresh.store.runsForSession(session.id), isEmpty);
      expect(_runRows(inspection), isEmpty);
      expect(run.run.state, state);
      expect(run.run.interruptions, interruptions);
      if (waiting) {
        final recovered = fresh.lifecycle.recoveredRun(run.run.id)!;
        expect(recovered.status, RecoveredRunStatus.interrupted);
        expect(recovered.activity.state, RunState.waiting);
        expect(recovered.activity.tools.single.outcome, isNull);
        expect(
          recovered.activity.tools.single.changes.last.kind,
          ToolActivityKind.approvalRequested,
        );
      } else {
        expect(fresh.lifecycle.recoveredRun(run.run.id), isNull);
        _expectNoEvidence(inspection);
      }
    });
  }

  test(
    'approval completion retains only the final terminal state once',
    () async {
      final run = await createRun(decision: ToolPolicyDecision.ask);
      await run.start();
      expect(run.run.state, RunState.waiting);
      expect(runtime.store.runsForSession(session.id), isEmpty);
      expect(_runRows(inspection), isEmpty);
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      tool.beforeTerminal = () async {
        entered.complete();
        await release.future;
      };
      final advancing = run.resolveApproval(_approval(run.run));
      await entered.future;
      expect(run.run.state, RunState.running);
      expect(runtime.store.runRecord(run.run.id), isNull);
      expect(_runRows(inspection), isEmpty);
      release.complete();
      await advancing;
      expect(run.run.state, RunState.completed);
      expect(run.run.interruptions, isEmpty);
      expect(execution.approvalCalls, 1);
      expect(model.calls, 1);
      expect(tool.executions, 1);
      expectRetained(runtime, run, RunTerminalState.completed);
      _rejectRunInsert(inspection);
      await run.close();
      final fresh = await reopen(run);
      expectRetained(fresh, run, RunTerminalState.completed);
    },
  );

  for (final completed in [false, true]) {
    test(
      'application exit seals ${completed ? 'already terminal' : 'in-flight tool'} evidence before runtime retirement',
      () async {
        final run = await createRun();
        final entered = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        Future<void> suspend() async {
          entered.complete();
          await release.future;
        }

        if (completed) {
          execution.afterCompletion = suspend;
        } else {
          tool.beforeTerminal = suspend;
        }
        final advancing = run.start();
        final interrupted = expectLater(advancing, throwsA(anything));
        await entered.future;
        final state = completed ? RunState.completed : RunState.running;
        expect(run.run.state, state);
        expect(_runRows(inspection), isEmpty);
        final evidence = run.run.journal.records;
        final committed = _executionRows(inspection);
        final closing = run.close();
        run.interruptForApplicationExit();
        // Retention at the hard boundary is synchronous, not a late finalizer.
        if (completed) {
          expectRetained(runtime, run, RunTerminalState.completed);
        } else {
          expect(_runRows(inspection), isEmpty);
          _expectCommittedPrefix(runtime, run);
        }
        run.interruptForApplicationExit();
        await runtime.close();
        if (!completed) {
          await interrupted.timeout(const Duration(seconds: 1));
          await closing.timeout(const Duration(seconds: 1));
        }
        release.completeError(StateError('late strategy or stream failure'));
        await interrupted;
        await closing;
        await Future<void>.delayed(Duration.zero);
        expect(run.run.state, state);
        expect(run.run.failure, isNull);
        expect(run.run.journal.records, evidence);
        if (!completed) expect(_executionRows(inspection), committed);
        expect(execution.closeCalls, 1);
        final fresh = await reopen(run);
        if (completed) {
          expectRetained(fresh, run, RunTerminalState.completed);
        } else {
          expect(fresh.store.runRecord(run.run.id), isNull);
          expect(fresh.lifecycle.runActivity(run.run.id), isNull);
          expect(_runRows(inspection), isEmpty);
          expect(_executionRows(inspection), committed);
          final recovered = fresh.lifecycle.recoveredRun(run.run.id)!;
          expect(recovered.status, RecoveredRunStatus.interrupted);
          expect(recovered.activity.tools.single.outcome, isNull);
          expect(
            recovered.activity.tools.single.changes.last.kind,
            ToolActivityKind.executionStarted,
          );
        }
      },
    );
  }

  for (final resume in [false, true]) {
    for (final strategyFails in [false, true]) {
      test('${resume ? 'approval' : 'start'} SQLite failure '
          '${strategyFails ? 'preserves primary strategy error' : 'surfaces without changing live completion'} '
          'and close never retries', () async {
        final run = await createRun(
          decision: resume ? ToolPolicyDecision.ask : ToolPolicyDecision.allow,
        );
        if (resume) await run.start();
        final primary = StateError('primary strategy failure');
        if (strategyFails) execution.failure = primary;
        _rejectRunInsert(inspection);
        await expectLater(
          resume ? run.resolveApproval(_approval(run.run)) : run.start(),
          throwsA(
            strategyFails
                ? same(primary)
                : isA<SqliteException>().having(
                    (error) => error.message,
                    'message',
                    contains('durable-run-insert-failure'),
                  ),
          ),
        );
        expect(
          run.run.state,
          strategyFails ? RunState.failed : RunState.completed,
        );
        expect(run.run.failure, strategyFails ? same(primary) : isNull);
        final events = run.run.journal.records.map((record) => record.event);
        expect(events.whereType<RunFailed>(), hasLength(strategyFails ? 1 : 0));
        expect(
          events.whereType<RunCompleted>(),
          hasLength(strategyFails ? 0 : 1),
        );
        expect(model.calls, 1);
        expect(tool.executions, 1);
        expect(execution.closeCalls, 1);
        expect(runtime.store.runRecord(run.run.id), isNull);
        expect(runtime.store.runsForSession(session.id), isEmpty);
        expect(runtime.lifecycle.runActivity(run.run.id), isNull);
        expect(runtime.lifecycle.runActivitiesForSession(session.id), isEmpty);
        expect(_runRows(inspection), isEmpty);
        final prefix = _beforeTerminal(run.activity.snapshot);
        _expectCommittedPrefix(runtime, run, expected: prefix);
        final committed = _executionRows(inspection);

        // Use the lifecycle's same connection, not the inspection connection,
        // to prove the failed terminal transaction left storage usable.
        final other = runtime.lifecycle.createSession(
          taskId: session.taskId,
          strategyId: _strategy,
        );
        expect(runtime.store.session(other.id), same(other));
        expect(
          inspection
              .select('SELECT id FROM adele_product_sessions ORDER BY id')
              .map((row) => row['id']),
          unorderedEquals([session.id.value, other.id.value]),
        );
        inspection.execute('DROP TRIGGER reject_run_insert');
        final evidence = run.run.journal.records;
        await run.close();
        await run.close();
        expect(execution.closeCalls, 1);
        expect(run.run.journal.records, orderedEquals(evidence));
        expect(runtime.store.runRecord(run.run.id), isNull);
        expect(_runRows(inspection), isEmpty);
        final fresh = await reopen(run, expectedRecovered: prefix);
        expect(fresh.store.session(other.id), isNotNull);
        expect(fresh.store.runRecord(run.run.id), isNull);
        expect(fresh.store.runsForSession(session.id), isEmpty);
        expect(_runRows(inspection), isEmpty);
        expect(_executionRows(inspection), committed);
        expect(
          fresh.lifecycle.recoveredRun(run.run.id)!.status,
          RecoveredRunStatus.interrupted,
        );
      });
    }
  }

  for (final recordingFails in [false, true]) {
    test(
      'close drains detached mechanics before ${recordingFails ? 'recording and cleanup fail' : 'retaining deferred failure'}',
      () async {
        final storageFailure = isA<SqliteException>().having(
          (error) => error.message,
          'message',
          contains('durable-run-insert-failure'),
        );
        final run = await createRun(
          expectedCloseFailure: recordingFails ? storageFailure : null,
        );
        if (recordingFails) {
          _rejectRunInsert(inspection);
          execution.closeFailure = StateError('secondary cleanup failure');
        }
        final entered = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        tool.beforeTerminal = () async {
          entered.complete();
          await release.future;
        };
        late Future<StrategyToolResult> mechanics;
        late Object primary;
        execution.beforeProposal = () async {
          mechanics = execution.host.processProposal(
            tools: execution.turn.tools,
            proposal: execution.turn.output
                .whereType<ModelToolProposalOutput>()
                .single
                .proposal,
          );
          await entered.future;
          try {
            execution.host.complete();
          } on Object catch (error) {
            primary = error;
            rethrow;
          }
        };
        await expectLater(run.start(), throwsA(isA<InvalidRunOperation>()));
        expect(run.run.state, RunState.running);
        expect(run.run.failure, isNull);
        expect(runtime.store.runRecord(run.run.id), isNull);
        expect(_runRows(inspection), isEmpty);
        expect(execution.closeCalls, 0);
        final closing = run.close();
        expect(run.close(), same(closing));
        final observed = recordingFails
            ? expectLater(closing, throwsA(storageFailure))
            : closing;
        release.complete();
        await mechanics;
        await observed;
        expect(run.run.state, RunState.failed);
        expect(run.run.failure, same(primary));
        expect(
          run.run.journal.records.reversed
              .take(2)
              .map((record) => record.event),
          [isA<RunFailed>(), isA<ToolExecutionCompleted>()],
        );
        expect(execution.closeCalls, 1);
        if (recordingFails) {
          expect(runtime.store.runRecord(run.run.id), isNull);
          expect(_runRows(inspection), isEmpty);
          inspection.execute('DROP TRIGGER reject_run_insert');
          expect(run.close(), same(closing));
          await expectLater(run.close(), throwsA(storageFailure));
          expect(execution.closeCalls, 1);
          expect(_runRows(inspection), isEmpty);
        } else {
          expectRetained(runtime, run, RunTerminalState.failed);
        }
        final fresh = await reopen(
          run,
          expectedRecovered: recordingFails
              ? _beforeTerminal(run.activity.snapshot)
              : null,
        );
        if (recordingFails) {
          expect(fresh.store.runRecord(run.run.id), isNull);
          expect(fresh.store.runsForSession(session.id), isEmpty);
        } else {
          expectRetained(fresh, run, RunTerminalState.failed);
        }
      },
    );
  }

  for (final boundary in [
    'model output',
    'second model invocation',
    'prepared tool',
    'tool execution start',
  ]) {
    test('reopen preserves $boundary without inventing settlement', () async {
      final run = await createRun();
      final gate = _Gate();
      addTearDown(gate.release);
      switch (boundary) {
        case 'model output':
          model.beforeTerminal = (_) => gate.wait();
        case 'second model invocation':
          execution.invokeAgain = true;
          model.beforeTerminal = (call) async {
            if (call == 2) await gate.wait();
          };
        case 'prepared tool':
          tool.beforeDescribe = gate.wait;
        case 'tool execution start':
          tool.beforeTerminal = gate.wait;
      }
      final advancing = expectLater(run.start(), throwsA(anything));
      await gate.entered.future;
      if (boundary == 'model output' || boundary == 'second model invocation') {
        await _waitForActivity(
          run,
          (activity) =>
              activity.models.length == model.calls &&
              activity.models.last.outputs.length == 3,
        );
      }
      final prefix = run.activity.snapshot;
      _expectCommittedPrefix(runtime, run);
      expect(prefix.state, RunState.running);
      expect(prefix.failure, isNull);
      switch (boundary) {
        case 'model output':
          expect(prefix.models.single.startSequence, 2);
          expect(prefix.models.single.outputs.map((item) => item.sequence), [
            4,
            5,
            6,
          ]);
          expect(prefix.models.single.terminalSequence, isNull);
          expect(prefix.models.single.settlement, isNull);
          expect(prefix.models.single.failure, isNull);
          expect(prefix.tools, isEmpty);
        case 'second model invocation':
          expect(prefix.models, hasLength(2));
          expect(prefix.models.first.settlement, ModelSettlement.completed);
          expect(prefix.models.first.terminalSequence, 7);
          expect(prefix.models.last.terminalSequence, isNull);
          expect(prefix.models.last.settlement, isNull);
          expect(prefix.models.last.failure, isNull);
          final completed = prefix.tools.single;
          expect(completed.modelInvocationId, prefix.models.first.id);
          expect(completed.proposalSequence, 6);
          expect(
            completed.outcome!.effectCertainty,
            EffectCertainty.knownOccurred,
          );
        case 'prepared tool':
          expect(prefix.tools.single.changes.map((change) => change.kind), [
            ToolActivityKind.prepared,
          ]);
          expect(prefix.tools.single.effects, isNull);
          expect(prefix.tools.single.outcome, isNull);
          expect(tool.executions, 0);
        case 'tool execution start':
          expect(
            prefix.tools.single.changes.last.kind,
            ToolActivityKind.executionStarted,
          );
          expect(prefix.tools.single.outcome, isNull);
          expect(tool.executions, 1);
      }
      final committed = _executionRows(inspection);
      run.interruptForApplicationExit();
      gate.release();
      await advancing;
      await run.close();
      // Late successful provider/tool continuation cannot append after cutoff,
      // even while the original database is still open and writable.
      expect(_executionRows(inspection), committed);
      _expectActivity(run.activity.snapshot, prefix);
      final fresh = await reopen(run, expectedRecovered: prefix);
      expect(
        fresh.lifecycle.recoveredRun(run.run.id)!.status,
        RecoveredRunStatus.interrupted,
      );
      expect(fresh.lifecycle.runActivity(run.run.id), isNull);
      expect(fresh.store.runRecord(run.run.id), isNull);
    });
  }

  for (final approved in [false, true]) {
    test('resolved approval ${approved ? 'with dispatch' : 'without dispatch'} '
        'reopens as evidence, never actionable authority', () async {
      final run = await createRun(decision: ToolPolicyDecision.ask);
      await run.start();
      final resolution = _approval(run.run, approved: approved);
      final gate = _Gate();
      addTearDown(gate.release);
      if (approved) {
        tool.beforeTerminal = gate.wait;
      } else {
        execution.afterApproval = gate.wait;
      }
      final advancing = expectLater(
        run.resolveApproval(resolution),
        throwsA(anything),
      );
      await gate.entered.future;
      final prefix = run.activity.snapshot;
      _expectCommittedPrefix(runtime, run);
      expect(prefix.state, RunState.running);
      expect(run.run.interruptions, isEmpty);
      final activity = prefix.tools.single;
      final request = activity.changes.singleWhere(
        (change) => change.kind == ToolActivityKind.approvalRequested,
      );
      final resolved = activity.changes.singleWhere(
        (change) => change.kind == ToolActivityKind.approvalResolved,
      );
      expect(request.interruptionId, resolution.interruptionId);
      expect(resolved.interruptionId, request.interruptionId);
      expect(resolved.approved, approved);
      expect(tool.executions, approved ? 1 : 0);
      if (approved) {
        expect(activity.changes.last.kind, ToolActivityKind.executionStarted);
        expect(activity.outcome, isNull);
      } else {
        expect(
          activity.changes.map((change) => change.kind),
          isNot(contains(ToolActivityKind.executionStarted)),
        );
        expect(
          activity.outcome!.disposition,
          ToolOutcomeDisposition.userRejected,
        );
        expect(
          activity.outcome!.effectCertainty,
          EffectCertainty.knownNotOccurred,
        );
      }
      run.interruptForApplicationExit();
      gate.release();
      await advancing;
      await run.close();
      final fresh = await reopen(run, expectedRecovered: prefix);
      expect(
        fresh.lifecycle.recoveredRun(run.run.id)!.status,
        RecoveredRunStatus.interrupted,
      );
      expect(
        fresh.lifecycle.hasSessionExecution(fresh.store.session(session.id)!),
        isFalse,
      );
    });
  }

  test(
    'cancelled Run seals its previously committed approval prefix once',
    () async {
      final run = await createRun(decision: ToolPolicyDecision.ask);
      await run.start();
      _expectCommittedPrefix(runtime, run);
      run.run.cancel();
      await run.close();
      expectRetained(runtime, run, RunTerminalState.cancelled);
      expect(run.activity.snapshot.tools.single.outcome, isNull);
      _rejectRunInsert(inspection);
      await run.close();
      final fresh = await reopen(run);
      expectRetained(fresh, run, RunTerminalState.cancelled);
      expect(
        fresh.lifecycle.recoveredRun(run.run.id)!.status,
        RecoveredRunStatus.terminal,
      );
    },
  );

  for (final resume in [false, true]) {
    test('${resume ? 'approved' : 'allowed'} tool start checkpoint failure '
        'prevents dispatch and cannot be retried', () async {
      final run = await createRun(
        decision: resume ? ToolPolicyDecision.ask : ToolPolicyDecision.allow,
      );
      if (resume) await run.start();
      inspection.execute('''
        CREATE TRIGGER reject_checkpoint BEFORE INSERT ON adele_execution_tool_changes
        WHEN NEW.kind = 'executionStarted'
        BEGIN SELECT RAISE(ABORT, 'checkpoint-failure'); END;
      ''');
      final failure = isA<SqliteException>().having(
        (error) => error.message,
        'message',
        contains('checkpoint-failure'),
      );
      await expectLater(
        resume ? run.resolveApproval(_approval(run.run)) : run.start(),
        throwsA(failure),
      );
      expect(tool.executions, 0);
      expect(run.run.state, RunState.running);
      expect(run.run.failure, isNull);
      final live = run.activity.snapshot;
      final uncommitted = live.tools.single;
      expect(uncommitted.changes.last.kind, ToolActivityKind.executionStarted);
      final prefix = RunActivitySnapshot(
        runId: live.runId,
        sessionId: live.sessionId,
        state: live.state,
        sequence: live.sequence - 1,
        lifecycle: live.lifecycle,
        models: live.models,
        tools: [
          ToolInvocationActivity(
            id: uncommitted.id,
            preparedSequence: uncommitted.preparedSequence,
            modelInvocationId: uncommitted.modelInvocationId,
            proposalSequence: uncommitted.proposalSequence,
            toolId: uncommitted.toolId,
            alias: uncommitted.alias,
            providerCallId: uncommitted.providerCallId,
            canonicalArguments: uncommitted.canonicalArguments,
            changes: uncommitted.changes.take(uncommitted.changes.length - 1),
            effects: uncommitted.effects,
          ),
        ],
      );
      _expectCommittedPrefix(runtime, run, expected: prefix);
      final committed = _executionRows(inspection);
      inspection.execute('DROP TRIGGER reject_checkpoint');
      await expectLater(run.start(), throwsA(failure));
      await run.close();
      expect(tool.executions, 0);
      expect(_executionRows(inspection), committed);
      final fresh = await reopen(run, expectedRecovered: prefix);
      final recovered = fresh.lifecycle.recoveredRun(run.run.id)!;
      expect(recovered.activity.tools.single.outcome, isNull);
      expect(
        recovered.activity.tools.single.changes.last.kind,
        resume
            ? ToolActivityKind.approvalResolved
            : ToolActivityKind.policyEvaluated,
      );
      expect(fresh.store.runRecord(run.run.id), isNull);
    });
  }

  test(
    'failed approval checkpoint rolls back request and waiting together',
    () async {
      final run = await createRun(decision: ToolPolicyDecision.ask);
      inspection.execute('''
      CREATE TRIGGER reject_checkpoint BEFORE INSERT ON adele_execution_tool_changes
      WHEN NEW.kind = 'approvalRequested'
      BEGIN SELECT RAISE(ABORT, 'checkpoint-failure'); END;
    ''');
      await expectLater(run.start(), throwsA(isA<SqliteException>()));
      expect(tool.executions, 0);
      expect(run.run.state, RunState.waiting);
      expect(run.run.failure, isNull);
      final database = runtime.lifecycle.databaseForSession(session.id)!;
      expect(database.autocommit, isTrue);
      final prefix = database.loadExecutionRestoreSet([]).unsealed.single;
      expect(prefix.state, RunState.running);
      expect(prefix.sequence, 9);
      expect(prefix.lifecycle.map((entry) => (entry.sequence, entry.state)), [
        (1, RunState.running),
      ]);
      expect(prefix.models.single.terminalSequence, 7);
      expect(
        prefix.tools.single.changes.map(
          (entry) => (entry.sequence, entry.kind),
        ),
        [(8, ToolActivityKind.prepared), (9, ToolActivityKind.policyEvaluated)],
      );
      final committed = _executionRows(inspection);
      inspection.execute('DROP TRIGGER reject_checkpoint');
      await run.close();
      expect(_executionRows(inspection), committed);
      final fresh = await reopen(run, expectedRecovered: prefix);
      expect(
        fresh.lifecycle.recoveredRun(run.run.id)!.activity.state,
        RunState.running,
      );
      expect(fresh.store.runRecord(run.run.id), isNull);
    },
  );

  test(
    'SIGKILL after committed pre-dispatch prefix survives a fresh runtime',
    () async {
      final crashSource = Directory.systemTemp.createTempSync(
        'adele-killed-run-',
      );
      addTearDown(() => crashSource.deleteSync(recursive: true));
      final dart = _dartExecutable();
      final sdk = File(dart).parent.parent.path;
      final kernel = '${crashSource.path}/writer.dill';
      // Reuse Flutter's prepared assets, as configuration_store's writers do.
      // Nested `dart run` rebuilds hooks and prefixes our JSON with hook output.
      final compilation = await Process.run('$sdk/bin/dartaotruntime', [
        '$sdk/bin/snapshots/gen_kernel_aot.dart.snapshot',
        '--platform=$sdk/lib/_internal/vm_platform_strong.dill',
        '--packages=${File('../.dart_tool/package_config.json').absolute.path}',
        '--native-assets=${File('build/native_assets/linux/native_assets.json').absolute.path}',
        '--output=$kernel',
        'test/core/fixtures/partial_run_writer.dart',
      ]);
      expect(
        compilation.exitCode,
        0,
        reason: '${compilation.stdout}\n${compilation.stderr}',
      );
      final process = await Process.start(dart, [
        '--disable-dart-dev',
        kernel,
        crashSource.path,
      ]);
      final output = StringBuffer();
      final errorOutput = StringBuffer();
      final lines = StreamIterator(
        process.stdout
            .transform(utf8.decoder)
            .map((chunk) {
              output.write(chunk);
              return chunk;
            })
            .transform(const LineSplitter()),
      );
      final errors = process.stderr
          .transform(utf8.decoder)
          .forEach(errorOutput.write);
      String diagnostics() => 'stdout:\n$output\nstderr:\n$errorOutput';
      try {
        Future<Map<String, Object?>> checkpoint() async {
          while (await lines.moveNext()) {
            if (lines.current.startsWith('{')) {
              return jsonDecode(lines.current) as Map<String, Object?>;
            }
          }
          await errors;
          throw StateError(
            'Writer exited before checkpoint (${await process.exitCode}):\n'
            '${diagnostics()}',
          );
        }

        final marker = await checkpoint().timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw TimeoutException(
            'Writer did not reach its committed checkpoint.\n${diagnostics()}',
          ),
        );
        expect(marker['checkpoint'], 'committed');
        // The child is blocked on stdin, not a timer, and never runs close/finally.
        expect(process.kill(ProcessSignal.sigkill), isTrue);
        expect(await process.exitCode, -ProcessSignal.sigkill.signalNumber);
        await errors;
        expect(errorOutput.toString(), isEmpty);
        final ids = _NoAllocationIds();
        final fresh = AdeleRuntime(ids: ids, runIds: ids);
        addTearDown(fresh.close);
        final freshChannel = _ProviderChannel();
        _registerProviders(fresh, freshChannel);
        await fresh.lifecycle.openProject(
          sourceLocation: crashSource.uri,
          provider: fresh.lifecycle.resolveProjectProvider(_projectProvider),
        );
        final runId = RunId(marker['runId']! as String);
        final sessionId = SessionId(marker['sessionId']! as String);
        final recovered = fresh.lifecycle.recoveredRun(runId)!;
        expect(recovered.status, RecoveredRunStatus.interrupted);
        expect(recovered.terminalRecord, isNull);
        expect(recovered.session, same(fresh.store.session(sessionId)));
        expect(recovered.activity.state, RunState.running);
        expect(recovered.activity.sequence, marker['sequence']);
        expect(recovered.activity.failure, isNull);
        final model = recovered.activity.models.single;
        expect(model.id.value, marker['modelId']);
        expect(model.startSequence, 2);
        expect(model.outputs.map((output) => output.sequence), [4, 5]);
        expect(
          (model.outputs.first.item as ModelTextOutput).content,
          'Committed before kill',
        );
        expect(model.settlement, ModelSettlement.completed);
        final tool = recovered.activity.tools.single;
        expect(tool.id.value, marker['toolId']);
        expect(tool.modelInvocationId, model.id);
        expect(tool.proposalSequence, marker['proposalSequence']);
        expect(tool.providerCallId, 'kill-call');
        expect(tool.canonicalArguments, {'target': 'fixture'});
        expect(tool.changes.map((change) => change.kind), [
          ToolActivityKind.prepared,
          ToolActivityKind.policyEvaluated,
          ToolActivityKind.executionStarted,
        ]);
        expect(tool.outcome, isNull);
        expect(fresh.store.runRecord(runId), isNull);
        expect(fresh.store.runsForSession(sessionId), isEmpty);
        expect(fresh.lifecycle.runActivity(runId), isNull);
        expect(fresh.lifecycle.hasSessionExecution(recovered.session), isFalse);
        expect(fresh.lifecycle.recoveredRun(RunId('never-started')), isNull);
        expect(
          fresh.extensions.discover(orchestrationStrategyContributions),
          isEmpty,
        );
        expect(
          fresh.registry.providersFor(environmentProviderCapability),
          isEmpty,
        );
        expect(
          fresh.lifecycle.environmentRuntime.currentMaterialization(
            fresh.store.requireSessionAuthority(sessionId).environmentId,
          ),
          isNull,
        );
        expect(fresh.plugins.host, isNull);
        expect(freshChannel.environmentCalls, 0);
        expect(ids.calls, 0);
      } finally {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        await lines.cancel();
        await errors;
        await process.stdin.close();
      }
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<Session> _createSession(AdeleRuntime runtime, Directory source) async {
  final project = await runtime.lifecycle.openProject(
    sourceLocation: source.uri,
    provider: runtime.lifecycle.resolveProjectProvider(_projectProvider),
  );
  final task = await runtime.lifecycle.createTask(
    projectId: project.id,
    title: 'Durable Run',
    providerId: _environmentProvider,
  );
  return runtime.lifecycle.createSession(
    taskId: task.task.id,
    strategyId: _strategy,
  );
}

void _registerProviders(
  AdeleRuntime runtime,
  _ProviderChannel channel, {
  bool environment = false,
}) {
  for (final descriptor in [
    ProviderDescriptor(
      id: _projectProvider,
      capability: projectProviderCapability,
      pluginId: 'dev.adele.test.provider',
      displayName: 'Project',
      serviceId: projectProviderServiceId,
    ),
    if (environment)
      ProviderDescriptor(
        id: _environmentProvider,
        capability: environmentProviderCapability,
        pluginId: 'dev.adele.test.provider',
        displayName: 'Environment',
        serviceId: environmentProviderServiceId,
      ),
  ]) {
    final registration = runtime.registry.register(
      provider: descriptor,
      endpoint: AdeleRequestChannelEndpoint(
        channel: channel,
        serviceId: descriptor.serviceId,
        isAvailable: () => true,
      ),
    );
    addTearDown(registration.close);
  }
}

final class _ProviderChannel implements AdeleRequestChannel {
  int projectCalls = 0;
  int environmentCalls = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    if (method == projectProviderServicePrepareSourceId) {
      projectCalls++;
      return {
        'sourceLocation': payload['sourceLocation'],
        'databaseRelativePath': '.adele/data.db',
      };
    }
    expect(method, environmentProviderServiceEstablishId);
    environmentCalls++;
    return {'providerState': <String, Object?>{}, 'initialState': null};
  }
}

List<Map<String, Object?>> _runRows(Database database) => [
  for (final row in database.select(
    'SELECT * FROM adele_product_runs ORDER BY id',
  ))
    Map<String, Object?>.from(row),
];

void _rejectRunInsert(Database database) => database.execute('''
  CREATE TRIGGER reject_run_insert BEFORE INSERT ON adele_product_runs
  BEGIN SELECT RAISE(ABORT, 'durable-run-insert-failure'); END;
''');

Map<String, List<List<Object?>>> _executionRows(Database database) => {
  for (final row in database.select(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'adele_execution_%' ORDER BY name",
  ))
    row['name'] as String: database
        .select('SELECT * FROM ${row['name']} ORDER BY rowid')
        .map((value) => value.values.toList())
        .toList(),
};

RunActivitySnapshot _beforeTerminal(RunActivitySnapshot activity) =>
    RunActivitySnapshot(
      runId: activity.runId,
      sessionId: activity.sessionId,
      state: activity.lifecycle[activity.lifecycle.length - 2].state,
      sequence: activity.sequence - 1,
      lifecycle: activity.lifecycle.take(activity.lifecycle.length - 1),
      models: activity.models,
      tools: activity.tools,
      rejectedProposals: activity.rejectedProposals,
    );

void _expectCommittedPrefix(
  AdeleRuntime runtime,
  SessionOrchestrationRun run, {
  RunActivitySnapshot? expected,
}) {
  final database = runtime.lifecycle.databaseForSession(run.run.sessionId)!;
  expect(database.autocommit, isTrue);
  final restored = database.loadExecutionRestoreSet(
    database.loadProductGraph().runRecords,
  );
  expect(restored.terminal, isEmpty);
  _expectActivity(restored.unsealed.single, expected ?? run.activity.snapshot);
  expect(runtime.store.runRecord(run.run.id), isNull);
  expect(runtime.lifecycle.runActivity(run.run.id), isNull);
  // Recovery evidence is published on reopen, not as a second live authority.
  expect(runtime.lifecycle.recoveredRun(run.run.id), isNull);
}

void _expectNoEvidence(Database database) {
  for (final row in database.select(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'adele_execution_%'",
  )) {
    expect(database.select('SELECT * FROM ${row['name']}'), isEmpty);
  }
}

void _expectActivity(RunActivitySnapshot actual, RunActivitySnapshot expected) {
  expect(actual.runId, expected.runId);
  expect(actual.sessionId, expected.sessionId);
  expect(actual.state, expected.state);
  expect(actual.sequence, expected.sequence);
  expect(
    actual.lifecycle.map((entry) => (entry.sequence, entry.state)),
    expected.lifecycle.map((entry) => (entry.sequence, entry.state)),
  );
  expect(actual.failure?.kind, expected.failure?.kind);
  expect(actual.failure?.message, expected.failure?.message);
  expect(actual.failure?.providerCode, expected.failure?.providerCode);
  expect(actual.failure?.providerDetails, expected.failure?.providerDetails);
  expect(actual.models, hasLength(expected.models.length));
  for (var i = 0; i < actual.models.length; i++) {
    final model = actual.models[i];
    final original = expected.models[i];
    expect(model.id, original.id);
    expect(model.startSequence, original.startSequence);
    expect(model.terminalSequence, original.terminalSequence);
    expect(model.settlement, original.settlement);
    expect(model.incompleteReason, original.incompleteReason);
    expect(model.failure?.kind, original.failure?.kind);
    expect(model.failure?.message, original.failure?.message);
    expect(model.metadata?.effectiveModel, original.metadata?.effectiveModel);
    expect(
      model.metadata?.providerResponseId,
      original.metadata?.providerResponseId,
    );
    expect(
      model.outputs.map((entry) => entry.sequence),
      original.outputs.map((entry) => entry.sequence),
    );
    expect(
      model.outputs.map((entry) => entry.item.runtimeType),
      original.outputs.map((entry) => entry.item.runtimeType),
    );
    if (model.outputs.isEmpty) continue;
    final text = model.outputs.first.item as ModelTextOutput;
    expect(
      text.content,
      (original.outputs.first.item as ModelTextOutput).content,
    );
    expect(
      text.providerItemId,
      (original.outputs.first.item as ModelTextOutput).providerItemId,
    );
    if (model.outputs.length == 1) continue;
    final native = model.outputs[1].item as ModelNativeOutput;
    final originalNative = original.outputs[1].item as ModelNativeOutput;
    expect(native.providerItemId, originalNative.providerItemId);
    expect(native.presentation!.kind, originalNative.presentation!.kind);
    expect(
      native.providerNativeMetadata.kind,
      originalNative.providerNativeMetadata.kind,
    );
    expect(
      native.providerNativeMetadata.compatibility,
      originalNative.providerNativeMetadata.compatibility,
    );
    expect(
      native.providerNativeMetadata.data,
      originalNative.providerNativeMetadata.data,
    );
    expect(native.presentation!.data, originalNative.presentation!.data);
    expect(
      () => native.providerNativeMetadata.data.clear(),
      throwsUnsupportedError,
    );
    expect(() => native.presentation!.data.clear(), throwsUnsupportedError);
    expect(
      native.presentation!.compactText,
      originalNative.presentation!.compactText,
    );
    final proposal =
        (model.outputs.last.item as ModelToolProposalOutput).proposal;
    final originalProposal =
        (original.outputs.last.item as ModelToolProposalOutput).proposal;
    expect(proposal.providerCallId, originalProposal.providerCallId);
    expect(proposal.alias, originalProposal.alias);
    expect(proposal.arguments, originalProposal.arguments);
  }
  expect(actual.tools, hasLength(expected.tools.length));
  for (var i = 0; i < actual.tools.length; i++) {
    final tool = actual.tools[i];
    final original = expected.tools[i];
    expect(tool.id, original.id);
    expect(tool.modelInvocationId, original.modelInvocationId);
    expect(tool.proposalSequence, original.proposalSequence);
    expect(tool.preparedSequence, original.preparedSequence);
    expect(tool.toolId, original.toolId);
    expect(tool.alias, original.alias);
    expect(tool.providerCallId, original.providerCallId);
    expect(tool.canonicalArguments, original.canonicalArguments);
    expect(tool.effects?.effects, original.effects?.effects);
    expect(tool.effects?.summary, original.effects?.summary);
    expect(
      tool.changes.map((entry) => (entry.sequence, entry.kind)),
      original.changes.map((entry) => (entry.sequence, entry.kind)),
    );
    for (var j = 0; j < tool.changes.length; j++) {
      final change = tool.changes[j];
      final prior = original.changes[j];
      expect(change.policyDecision, prior.policyDecision);
      expect(change.interruptionId, prior.interruptionId);
      expect(change.approved, prior.approved);
      expect(change.effects?.effects, prior.effects?.effects);
      expect(change.effects?.summary, prior.effects?.summary);
      expect(change.progress?.content, prior.progress?.content);
      expect(change.progress?.kind, prior.progress?.kind);
      expect(change.outcome?.effectCertainty, prior.outcome?.effectCertainty);
    }
    expect(tool.outcome?.disposition, original.outcome?.disposition);
    expect(tool.outcome?.effectCertainty, original.outcome?.effectCertainty);
    expect(tool.outcome?.modelContent, original.outcome?.modelContent);
    expect(tool.outcome?.hostData, original.outcome?.hostData);
    expect(() => tool.changes.clear(), throwsUnsupportedError);
    expect(() => tool.canonicalArguments.clear(), throwsUnsupportedError);
  }
  expect(() => actual.lifecycle.clear(), throwsUnsupportedError);
  expect(() => actual.models.clear(), throwsUnsupportedError);
  expect(() => actual.tools.clear(), throwsUnsupportedError);
}

final class _NoAllocationIds implements ProductIdSource, RunIdSource {
  int calls = 0;
  Never _allocate() {
    calls++;
    throw StateError('Reopen must not allocate product or Run IDs.');
  }

  @override
  ProjectId nextProjectId() => _allocate();
  @override
  TaskId nextTaskId() => _allocate();
  @override
  EnvironmentId nextEnvironmentId() => _allocate();
  @override
  SessionId nextSessionId() => _allocate();
  @override
  RunId nextRunId() => _allocate();
}

final class _Execution implements OrchestrationExecution {
  _Execution(this.host);
  final OrchestrationExecutionHost host;
  Object? failure;
  Object? closeFailure;
  Future<void> Function()? beforeProposal;
  Future<void> Function()? afterCompletion;
  Future<void> Function()? afterApproval;
  bool invokeAgain = false;
  late StrategyModelTurn turn;
  int startCalls = 0;
  int approvalCalls = 0;
  int closeCalls = 0;

  @override
  Future<void> start() async {
    startCalls++;
    host.start();
    turn = await host.invokeModel(StrategyInferenceMaterial(input: const []));
    await beforeProposal?.call();
    await host.processProposal(
      tools: turn.tools,
      proposal: turn.output
          .whereType<ModelToolProposalOutput>()
          .single
          .proposal,
    );
    if (invokeAgain) {
      await host.invokeModel(StrategyInferenceMaterial(input: const []));
    }
    if (failure case final error?) throw error;
    if (host.state == RunState.running) host.complete();
    await afterCompletion?.call();
  }

  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) async {
    approvalCalls++;
    await host.resolveApproval(resolution);
    await afterApproval?.call();
    if (failure case final error?) throw error;
    host.complete();
  }

  @override
  Future<void> close() async {
    closeCalls++;
    if (closeFailure case final error?) throw error;
  }
}

final class _Model implements ModelPort {
  int calls = 0;
  Future<void> Function(int call)? beforeTerminal;

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    calls++;
    yield ModelObservationEvent(
      invocationId: request.invocationId,
      observation: ModelTextDeltaObservation('Retained'),
    );
    yield ModelOutputItemCompleted(
      invocationId: request.invocationId,
      item: ModelTextOutput('Retained text', providerItemId: 'text-1'),
    );
    yield ModelOutputItemCompleted(
      invocationId: request.invocationId,
      item: ModelNativeOutput(
        providerItemId: 'native-1',
        providerNativeMetadata: ModelNativeEnvelope(
          kind: 'fixture.native',
          compatibility: {'provider': 'fixture'},
          data: {'opaque': 'historical-only'},
        ),
        presentation: ModelNativePresentation(
          kind: 'fixture.presentation',
          compactText: 'Safe summary',
          data: {'summary': 'Safe summary'},
        ),
      ),
    );
    yield ModelOutputItemCompleted(
      invocationId: request.invocationId,
      item: ModelToolProposalOutput(
        ProviderToolProposal(
          providerCallId: 'call-1',
          alias: 'test_tool',
          arguments: const {},
        ),
      ),
    );
    await beforeTerminal?.call(calls);
    yield ModelInvocationSettledEvent(invocationId: request.invocationId);
  }
}

final class _Tool implements ToolExecutable {
  int executions = 0;
  Future<void> Function()? beforeTerminal;
  Future<void> Function()? beforeDescribe;

  @override
  CanonicalToolArguments validateAndNormalize(Map<String, Object?> arguments) =>
      CanonicalToolArguments(arguments);

  @override
  void validateBinding() {}

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async {
    await beforeDescribe?.call();
    return EffectDescription(
      effects: const [ToolEffect.sourceMutation],
      targets: const [],
      summary: 'Deterministic fixture effect',
    );
  }

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    executions++;
    await beforeTerminal?.call();
    yield ToolExecutionProgress(ToolProgress(content: 'Fixture progress'));
    yield ToolExecutionTerminal(
      ToolOutcome(
        disposition: ToolOutcomeDisposition.success,
        effectCertainty: EffectCertainty.knownOccurred,
        modelContent: 'Executed',
        hostData: {'result': 'safe evidence'},
        hostDiagnostic: 'private diagnostic must not survive',
        cause: StateError('private cause must not survive'),
      ),
    );
  }
}

ToolCatalog _catalog(ToolExecutable tool) => ToolCatalog()
  ..register(
    ToolRegistration(
      definition: ToolDefinition(
        id: ToolId('dev.adele.test.tool'),
        description: 'Test',
      ),
      modelDefinition: ModelToolDefinition(
        alias: 'test_tool',
        description: 'Test',
        argumentsSchema: const {},
      ),
      executable: tool,
    ),
  );

ToolApprovalResolution _approval(AgentRun run, {bool approved = true}) {
  final interruption =
      run.interruptions.values.single as ToolApprovalInterruption;
  return ToolApprovalResolution(
    interruptionId: interruption.id,
    toolInvocationId: interruption.toolInvocationId,
    approved: approved,
  );
}

final class _Policy implements ToolPolicy {
  const _Policy(this.decision);
  final ToolPolicyDecision decision;

  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) => decision;
}

final class _Gate {
  final entered = Completer<void>();
  final _release = Completer<void>();

  Future<void> wait() {
    entered.complete();
    return _release.future;
  }

  void release() {
    if (!_release.isCompleted) _release.complete();
  }
}

Future<void> _waitForActivity(
  SessionOrchestrationRun run,
  bool Function(RunActivitySnapshot) ready,
) async {
  if (ready(run.activity.snapshot)) return;
  await run.activity.changes.firstWhere((_) => ready(run.activity.snapshot));
}

String _dartExecutable() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final dart = File('$root/bin/cache/dart-sdk/bin/dart');
    if (dart.existsSync()) return dart.path;
  }
  var directory = File(Platform.resolvedExecutable).parent;
  while (!File('${directory.path}/dart-sdk/bin/dart').existsSync()) {
    if (directory.parent.path == directory.path) {
      throw StateError('Pinned Dart SDK not found.');
    }
    directory = directory.parent;
  }
  return '${directory.path}/dart-sdk/bin/dart';
}
