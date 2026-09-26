import 'dart:async';
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

  Future<AdeleRuntime> reopen(SessionOrchestrationRun run) async {
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
        _expectNoEvidence(inspection);

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
        final fresh = await reopen(run);
        expect(fresh.store.session(other.id), isNotNull);
        expect(fresh.store.runRecord(run.run.id), isNull);
        expect(fresh.store.runsForSession(session.id), isEmpty);
        expect(_runRows(inspection), isEmpty);
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
        final fresh = await reopen(run);
        if (recordingFails) {
          expect(fresh.store.runRecord(run.run.id), isNull);
          expect(fresh.store.runsForSession(session.id), isEmpty);
        } else {
          expectRetained(fresh, run, RunTerminalState.failed);
        }
      },
    );
  }
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
    return {'providerState': <String, Object?>{}};
  }
}

List<Map<String, Object?>> _runRows(Database database) => [
  for (final row in database.select(
    'SELECT * FROM adele_product_runs ORDER BY id',
  ))
    Map<String, Object?>.from(row),
];

void _rejectRunInsert(Database database) => database.execute('''
  CREATE TRIGGER reject_run_insert BEFORE INSERT ON adele_execution_model_outputs
  BEGIN SELECT RAISE(ABORT, 'durable-run-insert-failure'); END;
''');

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
    expect(
      model.outputs.map((entry) => entry.sequence),
      original.outputs.map((entry) => entry.sequence),
    );
    expect(
      model.outputs.map((entry) => entry.item.runtimeType),
      original.outputs.map((entry) => entry.item.runtimeType),
    );
    final text = model.outputs.first.item as ModelTextOutput;
    expect(
      text.content,
      (original.outputs.first.item as ModelTextOutput).content,
    );
    expect(text.providerItemId, 'text-1');
    final native = model.outputs[1].item as ModelNativeOutput;
    final originalNative = original.outputs[1].item as ModelNativeOutput;
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
    expect(tool.canonicalArguments, original.canonicalArguments);
    expect(tool.effects!.effects, original.effects!.effects);
    expect(tool.effects!.summary, original.effects!.summary);
    expect(
      tool.changes.map((entry) => (entry.sequence, entry.kind)),
      original.changes.map((entry) => (entry.sequence, entry.kind)),
    );
    expect(tool.outcome!.disposition, original.outcome!.disposition);
    expect(tool.outcome!.effectCertainty, original.outcome!.effectCertainty);
    expect(tool.outcome!.modelContent, original.outcome!.modelContent);
    expect(tool.outcome!.hostData, original.outcome!.hostData);
  }
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
    if (failure case final error?) throw error;
    if (host.state == RunState.running) host.complete();
  }

  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) async {
    approvalCalls++;
    await host.resolveApproval(resolution);
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
    yield ModelInvocationSettledEvent(invocationId: request.invocationId);
  }
}

final class _Tool implements ToolExecutable {
  int executions = 0;
  Future<void> Function()? beforeTerminal;

  @override
  CanonicalToolArguments validateAndNormalize(Map<String, Object?> arguments) =>
      CanonicalToolArguments(arguments);

  @override
  void validateBinding() {}

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async => EffectDescription(
    effects: const [ToolEffect.sourceMutation],
    targets: const [],
    summary: 'Deterministic fixture effect',
  );

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

ToolApprovalResolution _approval(AgentRun run) {
  final interruption =
      run.interruptions.values.single as ToolApprovalInterruption;
  return ToolApprovalResolution(
    interruptionId: interruption.id,
    toolInvocationId: interruption.toolInvocationId,
    approved: true,
  );
}

final class _Policy implements ToolPolicy {
  const _Policy(this.decision);
  final ToolPolicyDecision decision;

  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) => decision;
}
