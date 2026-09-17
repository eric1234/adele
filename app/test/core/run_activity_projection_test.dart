import 'dart:async';
import 'dart:io';

import 'package:adele_desktop/core/run_activity_projection.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'live invalidations do not eagerly freeze progress history per microtask',
    () async {
      final AgentRun run = AgentRun(
        id: RunId('live-burst'),
        sessionId: SessionId('s'),
      )..start();
      final ToolInvocationId id = await _recordTool(run, 'active');
      final RunActivitySource source = RunActivityProjection(run).source;
      final RunActivitySnapshot before = source.snapshot;
      int notifications = 0;
      final subscription = source.changes.listen((_) => notifications++);
      addTearDown(subscription.cancel);
      const int count = 32000;
      final int firstSequence = run.journal.lastSequence + 1;
      final Stopwatch stopwatch = Stopwatch()..start();
      for (int i = 0; i < count; i++) {
        run.record(
          ToolProgressObserved(
            invocationId: id,
            progress: ToolProgress(content: 'x'),
          ),
        );
        await Future<void>.value();
      }
      await Future<void>.delayed(Duration.zero);
      final RunActivitySnapshot after = source.snapshot;
      stopwatch.stop();
      expect(notifications, greaterThan(1));
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(after.tools.single.changes, hasLength(3 + count));
      expect(
        after.tools.single.changes.skip(3).map((change) => change.sequence),
        List.generate(count, (index) => firstSequence + index),
      );
      expect(before.tools.single.changes, hasLength(3));
      expect(before.sequence, lessThan(after.sequence));
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );

  for (final int count in [16000, 32000]) {
    test(
      '$count buffered progress records freeze once without changing old snapshots',
      () async {
        final AgentRun run = AgentRun(
          id: RunId('burst-$count'),
          sessionId: SessionId('s'),
        )..start();
        final ToolInvocationId id = await _recordTool(run, 'active');
        await _recordTool(run, 'untouched');
        final RunActivitySource source = RunActivityProjection(run).source;
        final RunActivitySnapshot before = source.snapshot;
        final ToolInvocationActivity oldTool = before.tools.first;
        final int firstSequence = run.journal.lastSequence + 1;
        final List<ToolProgress> progress = List.generate(
          count,
          (index) => ToolProgress(
            kind: index.isEven
                ? ToolProgressKind.stdout
                : ToolProgressKind.stderr,
            content: String.fromCharCode(97 + index % 26),
          ),
        );
        for (final ToolProgress item in progress) {
          run.record(ToolProgressObserved(invocationId: id, progress: item));
        }

        final Stopwatch stopwatch = Stopwatch()..start();
        final RunActivitySnapshot snapshot = source.snapshot;
        stopwatch.stop();
        stdout.writeln(
          '$count buffered progress snapshot: ${stopwatch.elapsedMicroseconds / 1000} ms',
        );
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
        final ToolInvocationActivity tool = snapshot.tools.first;
        expect(tool.id, same(id));
        expect(tool.changes, hasLength(oldTool.changes.length + count));
        for (int index = 0; index < count; index++) {
          final ToolActivityChange change =
              tool.changes[oldTool.changes.length + index];
          expect(change.kind, ToolActivityKind.progress);
          expect(change.sequence, firstSequence + index);
          expect(change.progress, same(progress[index]));
        }
        expect(snapshot.sequence, firstSequence + count - 1);
        expect(snapshot.tools.last, same(before.tools.last));
        for (int index = 0; index < before.models.length; index++) {
          expect(snapshot.models[index], same(before.models[index]));
        }
        expect(oldTool.changes, hasLength(3));
        expect(oldTool.outcome, isNull);
        expect(oldTool.canonicalArguments, {
          'nested': <Object?>[
            {'value': 'active'},
          ],
        });
        expect(() => tool.changes.clear(), throwsUnsupportedError);
        expect(
          () => (tool.canonicalArguments['nested']! as List<Object?>).clear(),
          throwsUnsupportedError,
        );
        expect(source.snapshot, same(snapshot));

        run.record(
          ToolExecutionCompleted(
            invocationId: id,
            outcome: ToolOutcome(
              disposition: ToolOutcomeDisposition.success,
              effectCertainty: EffectCertainty.knownOccurred,
              modelContent: 'Complete.',
            ),
          ),
        );
        final ToolInvocationActivity completed = source.snapshot.tools.first;
        expect(completed.outcome!.disposition, ToolOutcomeDisposition.success);
        expect(completed.changes.last.kind, ToolActivityKind.completed);
        expect(
          completed.changes[oldTool.changes.length],
          same(tool.changes[oldTool.changes.length]),
        );
        expect(tool.outcome, isNull);
        expect(tool.changes, hasLength(oldTool.changes.length + count));
        expect(oldTool.changes, hasLength(3));
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );
  }

  test(
    'buffered completed model outputs preserve original item identities',
    () {
      final AgentRun run = AgentRun(
        id: RunId('outputs'),
        sessionId: SessionId('s'),
      )..start();
      final ModelInvocationId id = ModelInvocationId('model');
      run.record(ModelInvocationStarted(id));
      final RunActivitySource source = RunActivityProjection(run).source;
      final RunActivitySnapshot before = source.snapshot;
      const int count = 32000;
      final List<ModelTextOutput> outputs = List.generate(
        count,
        (index) => ModelTextOutput('x', providerItemId: 'item-$index'),
      );
      for (final ModelTextOutput item in outputs) {
        run.record(ModelOutputObserved(invocationId: id, item: item));
      }
      final ModelTerminalMetadata metadata = ModelTerminalMetadata(
        effectiveModel: 'buffered',
      );
      run.record(
        ModelInvocationSettled(
          invocationId: id,
          settlement: ModelSettlement.completed,
          incompleteReason: null,
          metadata: metadata,
        ),
      );
      final Stopwatch stopwatch = Stopwatch()..start();
      final ModelInvocationActivity model = source.snapshot.models.single;
      stopwatch.stop();
      stdout.writeln(
        '$count buffered model outputs snapshot: ${stopwatch.elapsedMicroseconds / 1000} ms',
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(model.outputs, hasLength(count));
      for (int index = 0; index < count; index++) {
        expect(model.outputs[index].sequence, index + 3);
        expect(model.outputs[index].item, same(outputs[index]));
      }
      expect(model.metadata, same(metadata));
      expect(model.settlement, ModelSettlement.completed);
      expect(model.terminalSequence, count + 3);
      expect(before.models.single.outputs, isEmpty);
      expect(before.models.single.metadata, isNull);
      expect(() => model.outputs.clear(), throwsUnsupportedError);
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );

  test(
    'repeated small reads freeze only changed entities and keep old prefixes',
    () async {
      final AgentRun run = AgentRun(
        id: RunId('small-reads'),
        sessionId: SessionId('s'),
      )..start();
      final ToolInvocationId toolId = await _recordTool(run, 'active');
      await _recordTool(run, 'untouched');
      final ModelInvocationId modelId = ModelInvocationId('live-model');
      run.record(ModelInvocationStarted(modelId));
      final RunActivitySource source = RunActivityProjection(run).source;
      final List<RunActivitySnapshot> snapshots = [source.snapshot];
      for (int index = 0; index < 32; index++) {
        final RunActivitySnapshot previous = snapshots.last;
        final ToolProgress progress = ToolProgress(content: '$index');
        final ExecutionEventRecord recorded = run.record(
          ToolProgressObserved(invocationId: toolId, progress: progress),
        );
        final RunActivitySnapshot toolSnapshot = source.snapshot;
        expect(
          toolSnapshot.tools.first.changes.last.sequence,
          recorded.sequence,
        );
        expect(toolSnapshot.tools.first.changes.last.progress, same(progress));
        expect(toolSnapshot.models.last, same(previous.models.last));
        expect(toolSnapshot.tools.last, same(previous.tools.last));
        expect(
          toolSnapshot.tools.first.effects,
          same(previous.tools.first.effects),
        );

        final ModelTextOutput output = ModelTextOutput('output-$index');
        run.record(ModelOutputObserved(invocationId: modelId, item: output));
        final RunActivitySnapshot snapshot = source.snapshot;
        expect(snapshot.models.last.outputs.last.item, same(output));
        expect(
          snapshot.models.last.startSequence,
          previous.models.last.startSequence,
        );
        expect(snapshot.tools.first, same(toolSnapshot.tools.first));
        expect(snapshot.models.first, same(previous.models.first));
        expect(snapshot.models.last.outputs, hasLength(index + 1));
        expect(snapshot.tools.first.changes, hasLength(index + 4));
        if (index > 0) {
          expect(
            snapshot.models.last.outputs.first,
            same(previous.models.last.outputs.first),
          );
          expect(
            snapshot.tools.first.changes[3],
            same(previous.tools.first.changes[3]),
          );
        }
        snapshots.add(snapshot);
        expect(source.snapshot, same(snapshot));
      }
      final ModelTerminalMetadata metadata = ModelTerminalMetadata();
      run.record(
        ModelInvocationSettled(
          invocationId: modelId,
          settlement: ModelSettlement.incomplete,
          incompleteReason: ModelIncompleteReason.outputLimit,
          metadata: metadata,
        ),
      );
      final RunActivitySnapshot terminal = source.snapshot;
      expect(terminal.models.last.metadata, same(metadata));
      expect(
        terminal.models.last.incompleteReason,
        ModelIncompleteReason.outputLimit,
      );
      expect(terminal.models.last.outputs, hasLength(32));
      expect(terminal.tools.first, same(snapshots.last.tools.first));
      for (int index = 0; index < snapshots.length; index++) {
        final RunActivitySnapshot old = snapshots[index];
        expect(old.models.last.outputs, hasLength(index));
        expect(old.models.last.terminalSequence, isNull);
        expect(old.models.last.metadata, isNull);
        expect(old.tools.first.changes, hasLength(index + 3));
        expect(old.tools.first.outcome, isNull);
        expect(() => old.models.last.outputs.clear(), throwsUnsupportedError);
        expect(() => old.tools.first.changes.clear(), throwsUnsupportedError);
      }
    },
  );

  test(
    'observers can detach and reattach without losing retained activity',
    () async {
      final AgentRun run = AgentRun(
        id: RunId('reattach'),
        sessionId: SessionId('s'),
      );
      final RunActivitySource source = RunActivityProjection(run).source;
      int firstNotifications = 0;
      final StreamSubscription<void> first = source.changes.listen(
        (_) => firstNotifications++,
      );
      run.start();
      await Future<void>.delayed(Duration.zero);
      expect(firstNotifications, 1);
      await first.cancel();
      final ModelInvocationId id = ModelInvocationId('m');
      run.record(ModelInvocationStarted(id));
      final RunActivitySnapshot detached = source.snapshot;
      int secondNotifications = 0;
      final StreamSubscription<void> second = source.changes.listen(
        (_) => secondNotifications++,
      );
      expect(source.snapshot, same(detached));
      run.record(
        ModelInvocationFailed(invocationId: id, error: StateError('private')),
      );
      run.fail(StateError('private'));
      await Future<void>.delayed(Duration.zero);
      expect(firstNotifications, 1);
      expect(secondNotifications, 1);
      expect(source.snapshot.state, RunState.failed);
      expect(source.snapshot.models.single.failure, isNotNull);
      expect(detached.models.single.failure, isNull);
      await second.cancel();
      int lateNotifications = 0;
      final StreamSubscription<void> late = source.changes.listen(
        (_) => lateNotifications++,
      );
      expect(source.snapshot.state, RunState.failed);
      await Future<void>.delayed(Duration.zero);
      expect(lateNotifications, 0);
      await late.cancel();
    },
  );

  test(
    'delta-only journal changes preserve snapshot identity and stay silent',
    () async {
      final AgentRun run = AgentRun(
        id: RunId('delta'),
        sessionId: SessionId('s'),
      );
      final RunActivityProjection projection = RunActivityProjection(run);
      final RunActivitySource source = projection.source;
      final RunActivitySnapshot initial = source.snapshot;
      expect(initial.state, RunState.created);
      expect(initial.sequence, 0);
      expect(initial.models, isEmpty);
      int changes = 0;
      final StreamSubscription<void> subscription = source.changes.listen(
        (_) => changes++,
      );
      run.start();
      final ModelInvocationId id = ModelInvocationId('m');
      run.record(ModelInvocationStarted(id));
      final RunActivitySnapshot started = source.snapshot;
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1); // Synchronous reads must not consume invalidations.
      expect(started.models.single.id, same(id));
      expect(started.models.single.startSequence, 2);
      for (int i = 0; i < 100; i++) {
        run.record(
          ModelObservationObserved(
            invocationId: id,
            observation: ModelTextDeltaObservation('delta'),
          ),
        );
        expect(source.snapshot, same(started));
      }
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1);
      final ModelTextOutput output = ModelTextOutput('Authoritative.');
      final ExecutionEventRecord observed = run.record(
        ModelOutputObserved(invocationId: id, item: output),
      );
      expect(
        source.snapshot.models.single.outputs.single.sequence,
        observed.sequence,
      );
      expect(observed.sequence, 103);
      expect(source.snapshot.models.single.outputs.single.item, same(output));
      expect(started.models.single.outputs, isEmpty);
      await subscription.cancel();
      run.record(
        ModelInvocationSettled(
          invocationId: id,
          settlement: ModelSettlement.completed,
          incompleteReason: null,
          metadata: ModelTerminalMetadata(),
        ),
      );
      run.complete();
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1);
      final RunActivitySnapshot terminal = source.snapshot;
      expect(terminal.state, RunState.completed);
      expect(terminal.models.single.terminalSequence, 104);
      expect(source.snapshot, same(terminal));
      expect(initial.state, RunState.created);
      expect(source, isNot(isA<RunActivityProjection>()));
      expect(source, isNot(isA<OrchestrationExecution>()));
      expect(() => (source as dynamic).run, throwsNoSuchMethodError);
      expect(() => (source as dynamic).start(), throwsNoSuchMethodError);
      expect(
        () => (source as dynamic).resolveApproval(null),
        throwsNoSuchMethodError,
      );
    },
  );

  test(
    'failed models retain native order, exact IDs, metadata and safe failures',
    () {
      final AgentRun run = AgentRun(
        id: RunId('failed'),
        sessionId: SessionId('s'),
      )..start();
      final ModelInvocationId id = ModelInvocationId('model');
      run.record(ModelInvocationStarted(id));
      final ModelNativeEnvelope envelope = ModelNativeEnvelope(
        kind: 'opaque',
        compatibility: {'v': 1},
        data: {
          'items': <Object?>[
            {'privateNative': 'retained'},
          ],
        },
      );
      final List<ModelOutputItem> outputs = [
        ModelNativeOutput(
          providerItemId: 'native-a',
          providerNativeMetadata: envelope,
        ),
        ModelTextOutput(
          'Partial.',
          providerItemId: 'text',
          providerNativeMetadata: envelope,
        ),
        ModelNativeOutput(
          providerItemId: 'native-b',
          providerNativeMetadata: envelope,
        ),
      ];
      for (final ModelOutputItem item in outputs) {
        run.record(
          ModelObservationObserved(
            invocationId: id,
            observation: ModelTextDeltaObservation('ignored'),
          ),
        );
        run.record(ModelOutputObserved(invocationId: id, item: item));
      }
      final ModelTerminalMetadata metadata = ModelTerminalMetadata(
        effectiveModel: 'exact-model',
        providerNativeState: envelope,
        usage: ModelUsage(
          inputTokens: 5,
          providerDetails: {
            'counts': <Object?>[2],
          },
        ),
      );
      final Object raw = _UnsafeException();
      final ModelFailure failure = ModelFailure(
        kind: ModelFailureKind.transport,
        providerCode: 'closed',
        providerMessage: 'Connection closed.',
        providerDetails: {
          'nested': <Object?>[
            {'code': 1},
          ],
        },
        cause: raw,
      );
      run.record(
        ModelInvocationFailed(
          invocationId: id,
          error: failure,
          semanticTerminalMetadata: metadata,
        ),
      );
      run.fail(raw);
      final RunActivitySource source = RunActivityProjection(run).source;
      final RunActivitySnapshot snapshot = source.snapshot;
      final ModelInvocationActivity model = snapshot.models.single;
      expect(model.id, same(id));
      expect(model.outputs.map((o) => o.sequence), [4, 6, 8]);
      for (int i = 0; i < outputs.length; i++) {
        expect(model.outputs[i].item, same(outputs[i]));
      }
      expect(model.terminalSequence, 9);
      expect(model.metadata, same(metadata));
      expect(model.settlement, isNull);
      expect(model.failure!.kind, 'transport');
      expect(model.failure!.providerCode, 'closed');
      expect(model.failure!.message, 'Connection closed.');
      expect(model.failure!.providerDetails, failure.providerDetails);
      expect(() => (model.failure as dynamic).cause, throwsNoSuchMethodError);
      expect(snapshot.state, RunState.failed);
      expect(snapshot.failure!.message, 'Run failed.');
      expect(snapshot.lifecycle.map((e) => e.state), [
        RunState.running,
        RunState.failed,
      ]);
      expect(snapshot.lifecycle.map((e) => e.sequence), [1, 10]);
      expect(source.snapshot, same(snapshot));
    },
  );

  test('cancelled-before-start and proposal-free models remain visible', () {
    final AgentRun cancelled = AgentRun(
      id: RunId('cancelled'),
      sessionId: SessionId('s'),
    );
    final RunActivitySource source = RunActivityProjection(cancelled).source;
    cancelled.cancel();
    expect(source.snapshot.state, RunState.cancelled);
    expect(source.snapshot.lifecycle.single.sequence, 1);
    final AgentRun run = AgentRun(
      id: RunId('empty-model'),
      sessionId: SessionId('s'),
    )..start();
    final ModelInvocationId id = ModelInvocationId('empty');
    run.record(ModelInvocationStarted(id));
    run.record(
      ModelInvocationSettled(
        invocationId: id,
        settlement: ModelSettlement.refused,
        incompleteReason: null,
        metadata: ModelTerminalMetadata(),
      ),
    );
    run.complete();
    final RunActivitySnapshot snapshot = RunActivityProjection(
      run,
    ).source.snapshot;
    expect(snapshot.models.single.outputs, isEmpty);
    expect(snapshot.models.single.settlement, ModelSettlement.refused);
    expect(snapshot.tools, isEmpty);
  });
}

Future<ToolInvocationId> _recordTool(AgentRun run, String suffix) async {
  final ModelInvocationId modelId = ModelInvocationId('model-$suffix');
  run.record(ModelInvocationStarted(modelId));
  final ProviderToolProposal proposal = ProviderToolProposal(
    providerCallId: 'call-$suffix',
    alias: 'tool',
    arguments: {
      'nested': <Object?>[
        {'value': suffix},
      ],
    },
  );
  final ExecutionEventRecord output = run.record(
    ModelOutputObserved(
      invocationId: modelId,
      item: ModelToolProposalOutput(proposal),
    ),
  );
  run.record(
    ModelInvocationSettled(
      invocationId: modelId,
      settlement: ModelSettlement.completed,
      incompleteReason: null,
      metadata: ModelTerminalMetadata(),
    ),
  );
  final ToolInvocation invocation =
      (await const ToolInvocationResolver().resolve(
                invocationId: ToolInvocationId('tool-$suffix'),
                proposal: proposal,
                tools: MaterializedToolSet([
                  MaterializedTool(
                    definition: ToolDefinition(
                      id: ToolId('test.tool'),
                      description: 'Journal fixture.',
                    ),
                    modelDefinition: ModelToolDefinition(
                      alias: 'tool',
                      description: 'Journal fixture.',
                      argumentsSchema: {},
                    ),
                    executable: _JournalExecutable(),
                  ),
                ]),
                context: ToolExecutionContext(
                  runId: run.id,
                  sessionId: run.sessionId,
                ),
              )
              as ResolvedToolProposal)
          .invocation;
  run.record(
    ToolInvocationPrepared(
      invocation,
      modelInvocationId: modelId,
      proposalSequence: output.sequence,
    ),
  );
  run.record(
    ToolPolicyEvaluated(
      invocationId: invocation.id,
      decision: ToolPolicyDecision.allow,
      effects: EffectDescription(
        effects: [ToolEffect.sourceRead],
        targets: [],
        summary: 'Read fixture.',
      ),
    ),
  );
  run.record(ToolExecutionStarted(invocation.id));
  return invocation.id;
}

final class _JournalExecutable implements ToolExecutable {
  @override
  CanonicalToolArguments validateAndNormalize(
    Map<String, Object?> proposedArguments,
  ) => CanonicalToolArguments(proposedArguments);

  @override
  void validateBinding() {}

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) => throw StateError('Journal-only fixture.');

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) => throw StateError('Journal-only fixture.');
}

final class _UnsafeException implements Exception {
  @override
  String toString() => throw StateError('Raw diagnostics must not be read.');
}
