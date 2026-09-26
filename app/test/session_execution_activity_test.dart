import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/frontend/session_execution_source.dart';
import 'package:adele_desktop/ui/execution/session_execution_controller.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'retained terminal evidence is Session-scoped read-only presentation',
    (tester) async {
      final runtime = AdeleRuntime();
      addTearDown(runtime.close);
      final project = Project(
        id: ProjectId('project'),
        sourceLocation: Uri.parse('file:///fixture/'),
      );
      final task = Task(
        id: TaskId('task'),
        projectId: project.id,
        title: 'Retained',
      );
      final environment = Environment(
        id: EnvironmentId('environment'),
        taskId: task.id,
        role: EnvironmentRole.primary,
        providerId: ProviderId('missing.environment'),
        providerState: const {},
      );
      final session = Session(
        id: SessionId('session'),
        taskId: task.id,
        strategyId: OrchestrationStrategyId('missing.strategy'),
      );
      final foreign = Session(
        id: SessionId('foreign'),
        taskId: task.id,
        strategyId: session.strategyId,
      );
      final missing = RunRecord(
        id: RunId('missing-evidence'),
        sessionId: session.id,
        state: RunTerminalState.failed,
      );
      runtime.store.publishRestoredProject(
        project: project,
        tasks: [task],
        environments: [environment],
        sessions: [session, foreign],
        authorities: [
          (session.id, environment.id),
          (foreign.id, environment.id),
        ],
        runRecords: [missing],
      );
      final raw = ModelNativeEnvelope(
        kind: 'fixture.raw',
        compatibility: const {},
        data: const {'encrypted': 'RETAINED-PRIVATE-ENVELOPE'},
      );
      final safe = ModelNativePresentation(
        kind: 'fixture.safe',
        compactText: 'Retained safe summary',
        data: const {'text': 'Approved detail'},
      );
      final runId = RunId('retained-run');
      final activity = RunActivitySnapshot(
        runId: runId,
        sessionId: session.id,
        state: RunState.completed,
        sequence: 7,
        lifecycle: const [
          RunLifecycleActivity(sequence: 1, state: RunState.running),
          RunLifecycleActivity(sequence: 7, state: RunState.completed),
        ],
        models: [
          ModelInvocationActivity(
            id: ModelInvocationId('model'),
            startSequence: 2,
            terminalSequence: 6,
            settlement: ModelSettlement.completed,
            metadata: ModelTerminalMetadata(),
            outputs: [
              ModelOutputActivity(
                sequence: 3,
                item: ModelNativeOutput(
                  providerNativeMetadata: raw,
                  presentation: safe,
                ),
              ),
              ModelOutputActivity(
                sequence: 4,
                item: ModelNativeOutput(providerNativeMetadata: raw),
              ),
              ModelOutputActivity(
                sequence: 5,
                item: ModelToolProposalOutput(
                  ProviderToolProposal(
                    providerCallId: 'proposal',
                    alias: 'missing_tool',
                    arguments: const {},
                  ),
                ),
              ),
            ],
          ),
        ],
      );
      runtime.lifecycle.retainTerminalRun(
        RunRecord(
          id: runId,
          sessionId: session.id,
          state: RunTerminalState.completed,
        ),
        activity,
      );
      final foreignRun = RunId('foreign-run');
      runtime.lifecycle.retainTerminalRun(
        RunRecord(
          id: foreignRun,
          sessionId: foreign.id,
          state: RunTerminalState.cancelled,
        ),
        RunActivitySnapshot(
          runId: foreignRun,
          sessionId: foreign.id,
          state: RunState.cancelled,
          sequence: 1,
          lifecycle: const [
            RunLifecycleActivity(sequence: 1, state: RunState.cancelled),
          ],
        ),
      );
      final controller = SessionExecutionController(
        runtime: runtime,
        session: session,
        providerId: ProviderId('missing.model'),
        model: null,
      );
      final inspection = WindowInspection()..presentSession(session);
      addTearDown(inspection.dispose);
      SessionExecutionPresentationSource source() =>
          SessionExecutionPresentationSource(
            controller: controller,
            extensions: runtime.extensions,
            isActive: () => true,
            inspect: (session, target) {
              final snapshot = controller.activityForRun(target.runId)!;
              return switch (target) {
                ActivityGroupInspectionTarget() => inspection.inspectActivity(
                  session: session,
                  activity: snapshot,
                  modelInvocationId: target.modelInvocationId,
                ),
                ModelOutputInspectionTarget() => inspection.inspectOutput(
                  session: session,
                  activity: snapshot,
                  modelInvocationId: target.modelInvocationId,
                  outputSequence: target.outputSequence,
                ),
              };
            },
          );
      final first = source();
      final other = source();
      addTearDown(first.invalidate);
      addTearDown(other.invalidate);
      expect(controller.activityForRun(runId), same(activity));
      expect(controller.stateForRun(runId), RunState.completed);
      expect(controller.stateForRun(missing.id), RunState.failed);
      expect(controller.stateForRun(foreignRun), isNull);
      expect(controller.activityForRun(foreignRun), isNull);
      expect(controller.activitySnapshots, [same(activity)]);
      for (final invalid in [
        '',
        ' retained-run',
        'absent',
        foreignRun.value,
        missing.id.value,
      ]) {
        expect(first.openRunActivity(invalid), isNull);
      }
      final handle = first.openRunActivity(runId.value)!;
      expect(handle, isNot(runId.value));
      expect(first.openRunActivity(runId.value), handle);
      expect(other.openRunActivity(runId.value), isNot(handle));
      expect(() => other.readRunActivity(handle), throwsStateError);
      expect(() => first.readRunActivity(runId.value), throwsStateError);
      final data = first.readRunActivity(handle);
      expect(data['state'], 'completed');
      expect(data.toString(), isNot(contains('RETAINED-PRIVATE-ENVELOPE')));
      final model = (data['models']! as List).single as Map;
      final outputs = model['outputs'] as List;
      final safeHandle = (outputs[0] as Map)['handle'] as String;
      final hiddenHandle = (outputs[1] as Map)['handle'] as String;
      expect(first.inspectActivity(hiddenHandle), isFalse);
      expect(first.inspectActivity(model['handle'] as String), isTrue);
      expect(first.inspectActivity(safeHandle), isTrue);
      expect(other.inspectActivity(safeHandle), isFalse);
      final presenter = runtime.extensions.register(
        point: modelNativeActivityPresentationContributions,
        id: ExtensionId('fixture.safe.presenter'),
        value: ModelNativeActivityPresentationContribution(
          presentationKind: safe.kind,
          createInspection: (presentation) {
            expect(presentation.data, {'text': 'Approved detail'});
            return Text(presentation.data['text']! as String);
          },
        ),
      );
      addTearDown(presenter.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InspectionHost(
              card: inspection.cards.first,
              activity: controller.activityForRun(runId),
              heading: 'Historical',
              extensions: runtime.extensions,
              onCollapse: () {},
              onExpand: () {},
              onDismiss: () {},
              onInspectOutput: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Approved detail'), findsOneWidget);
      expect(find.text('Retained safe summary'), findsOneWidget);
      expect(find.textContaining('RETAINED-PRIVATE-ENVELOPE'), findsNothing);
      expect(
        (activity.models.single.outputs.first.item as ModelNativeOutput)
            .providerNativeMetadata
            .data['encrypted'],
        'RETAINED-PRIVATE-ENVELOPE',
      );
      expect(controller.currentRun, isNull);
      expect(controller.activeRunFuture, isNull);
      expect(controller.pendingApproval, isNull);
      expect(controller.isRunning, isFalse);
      expect(controller.isAdvancing, isFalse);
      expect(controller.canStart, isFalse);
      expect(controller.revision, 0);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: first.buildActivity(safeHandle))),
      );
      await tester.pumpAndSettle();
      expect(find.text('Retained safe summary'), findsOneWidget);
      first.retainPresentation();
      await controller.close();
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: first.buildActivity(safeHandle))),
      );
      await tester.pumpAndSettle();
      expect(find.text('Retained safe summary'), findsOneWidget);
      expect(first.inspectActivity(safeHandle), isFalse);
      expect(() => first.openRunActivity(runId.value), throwsStateError);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'preparation failure remains failed throughout a successful retry',
    () async {
      final runtime = AdeleRuntime();
      final channel = _Channel();
      final providerId = ProviderId('dev.example.model');
      final providers = [
        runtime.registry.register(
          provider: ProviderDescriptor(
            id: providerId,
            capability: modelProviderCapability,
            pluginId: 'dev.example.model',
            displayName: 'Model',
            serviceId: modelProviderServiceId,
          ),
          endpoint: AdeleRequestChannelEndpoint(
            channel: channel,
            serviceId: modelProviderServiceId,
            isAvailable: () => true,
          ),
        ),
        runtime.registry.register(
          provider: ProviderDescriptor(
            id: ProviderId('dev.example.environment'),
            capability: environmentProviderCapability,
            pluginId: 'dev.example.environment',
            displayName: 'Environment',
            serviceId: environmentProviderServiceId,
          ),
          endpoint: AdeleRequestChannelEndpoint(
            channel: channel,
            serviceId: environmentProviderServiceId,
            isAvailable: () => true,
          ),
        ),
      ];
      final preparation = _Preparation();
      final tools = runtime.extensions.register(
        point: modelToolContributions,
        id: ExtensionId('dev.example.preparation'),
        value: preparation,
      );
      final strategyId = OrchestrationStrategyId('dev.example.strategy');
      var materializations = 0;
      final strategy = runtime.extensions.register(
        point: orchestrationStrategyContributions,
        id: ExtensionId('dev.example.strategy'),
        value: OrchestrationStrategyContribution(
          strategyId: strategyId,
          materialize: (context) {
            materializations++;
            return _Execution(context.host);
          },
        ),
      );
      final project = runtime.lifecycle.createProject(
        Uri.parse('file:///fixture/'),
      );
      final task = await runtime.lifecycle.createTask(
        projectId: project.id,
        title: 'Retry',
      );
      final session = runtime.lifecycle.createSession(
        taskId: task.task.id,
        strategyId: strategyId,
      );
      final controller = SessionExecutionController(
        runtime: runtime,
        session: session,
        providerId: providerId,
        model: 'fixture',
      );
      final source = SessionExecutionPresentationSource(
        controller: controller,
        extensions: runtime.extensions,
        isActive: () => true,
        inspect: (_, _) => false,
      );
      addTearDown(() async {
        if (!preparation.gate.isCompleted) preparation.gate.complete();
        source.invalidate();
        await controller.close();
        await tools.close();
        await strategy.close();
        for (final provider in providers) {
          await provider.close();
        }
        await runtime.close();
      });

      final failedHandle = await source.startRun();
      final failedAdvance = controller.activeRunFuture!;
      await preparation.entered.future;
      expect(source.readRunActivity(failedHandle)['state'], 'created');
      expect(controller.currentRun, isNull);
      preparation.gate.completeError(StateError('Tool preparation failed.'));
      await failedAdvance;
      final failed = source.readRunActivity(failedHandle);
      expect(failed['state'], 'failed');
      expect(failed['models'], isEmpty);
      expect(materializations, 0);
      expect(controller.activitySnapshots, isEmpty);
      expect(controller.canStart, isTrue);

      preparation.gate = Completer<void>();
      preparation.entered = Completer<void>();
      final retryHandle = await source.startRun();
      final retryAdvance = controller.activeRunFuture!;
      await preparation.entered.future;
      expect(retryHandle, isNot(failedHandle));
      expect(controller.isRunning, isTrue);
      expect(source.readRunActivity(retryHandle)['state'], 'created');
      expect(source.readRunActivity(failedHandle), failed);
      preparation.gate.complete();
      await retryAdvance;
      expect(source.readRunActivity(retryHandle)['state'], 'completed');
      expect(source.readRunActivity(failedHandle), failed);
      expect(materializations, 1);
      expect(controller.failure, isNull);
      expect(controller.activitySnapshots, hasLength(1));
      expect(source.inspectActivity(failedHandle), isFalse);
      source.invalidate();
      expect(() => source.readRunActivity(failedHandle), throwsStateError);
      expect(() => source.readRunActivity(retryHandle), throwsStateError);
    },
  );

  testWidgets('only emitted exact evidence gets inspect and compact actions', (
    tester,
  ) async {
    final runtime = AdeleRuntime();
    final channel = _Channel();
    final providerId = ProviderId('dev.example.model');
    final registrations = [
      runtime.registry.register(
        provider: ProviderDescriptor(
          id: providerId,
          capability: modelProviderCapability,
          pluginId: 'dev.example.model',
          displayName: 'Model',
          serviceId: modelProviderServiceId,
        ),
        endpoint: AdeleRequestChannelEndpoint(
          channel: channel,
          serviceId: modelProviderServiceId,
          isAvailable: () => true,
        ),
      ),
      runtime.registry.register(
        provider: ProviderDescriptor(
          id: ProviderId('dev.example.environment'),
          capability: environmentProviderCapability,
          pluginId: 'dev.example.environment',
          displayName: 'Environment',
          serviceId: environmentProviderServiceId,
        ),
        endpoint: AdeleRequestChannelEndpoint(
          channel: channel,
          serviceId: environmentProviderServiceId,
          isAvailable: () => true,
        ),
      ),
    ];
    final strategyId = OrchestrationStrategyId('dev.example.strategy');
    final strategy = runtime.extensions.register(
      point: orchestrationStrategyContributions,
      id: ExtensionId('dev.example.strategy'),
      value: OrchestrationStrategyContribution(
        strategyId: strategyId,
        materialize: (context) => _Execution(context.host),
      ),
    );
    final project = runtime.lifecycle.createProject(
      Uri.parse('file:///fixture/'),
    );
    final task = await runtime.lifecycle.createTask(
      projectId: project.id,
      title: 'Activity',
    );
    final session = runtime.lifecycle.createSession(
      taskId: task.task.id,
      strategyId: strategyId,
    );
    final controller = SessionExecutionController(
      runtime: runtime,
      session: session,
      providerId: providerId,
      model: 'fixture',
    );
    final targets = <InspectionTarget>[];
    var active = true;
    SessionExecutionPresentationSource source() =>
        SessionExecutionPresentationSource(
          controller: controller,
          extensions: runtime.extensions,
          isActive: () => active,
          inspect: (received, target) {
            expect(received, same(session));
            targets.add(target);
            return true;
          },
        );
    final first = source();
    final other = source();
    final handle = await first.startRun();
    final settling = controller.activeRunFuture!;
    expect(controller.isRunning, isTrue);
    await settling;
    final run = controller.currentRun!.run;
    expect(run.state, RunState.completed);
    expect(() => first.readRunActivity(run.id.value), throwsStateError);
    expect(() => other.readRunActivity(handle), throwsStateError);
    final snapshot = first.readRunActivity(handle);
    final model = (snapshot['models']! as List).single as Map<String, Object?>;
    final outputs = (model['outputs']! as List).cast<Map<String, Object?>>();
    expect(outputs.map((output) => output['kind']), [
      'text',
      'tool',
      'native',
      'native',
    ]);
    expect(outputs[1]['providerCallId'], 'call');
    expect(outputs[1]['arguments'], {
      'nested': [1, true, null],
    });
    expect(outputs[1]['tool'], isNull);
    expect(outputs[1]['rejection'], isNull);
    expect(() => snapshot['state'] = 'waiting', throwsUnsupportedError);
    expect(() => outputs[1]['tool'] = {}, throwsUnsupportedError);
    expect(
      () => ((outputs[1]['arguments']! as Map)['nested']! as List).clear(),
      throwsUnsupportedError,
    );
    expect(snapshot.toString(), isNot(contains('secret-raw-envelope')));
    expect(first.inspectActivity('p0-h9999'), isFalse);
    expect(first.inspectActivity(model['handle']! as String), isTrue);
    expect(targets.last, isA<ActivityGroupInspectionTarget>());
    expect(other.inspectActivity(model['handle']! as String), isFalse);
    expect(first.inspectActivity(outputs[0]['handle']! as String), isFalse);
    expect(first.inspectActivity(outputs[3]['handle']! as String), isFalse);
    final tool = outputs[1]['handle']! as String;
    expect(first.inspectActivity(tool), isTrue);
    final exact = targets.last as ModelOutputInspectionTarget;
    expect(exact.runId, run.id);
    expect(exact.outputSequence, outputs[1]['sequence']);
    final safe = outputs[2]['handle']! as String;
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: first.buildActivity(safe))),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Safe native'), findsOneWidget);
    final action = tester
        .widget<TextButton>(find.byType(TextButton).first)
        .onPressed!;
    action();
    expect(
      (targets.last as ModelOutputInspectionTarget).outputSequence,
      outputs[2]['sequence'],
    );
    final count = targets.length;
    active = false;
    action();
    expect(first.inspectActivity(tool), isFalse);
    expect(targets.length, count);
    active = true;
    first.retainPresentation();
    await controller.close();
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: first.buildActivity(safe))),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Safe native'), findsOneWidget);
    expect(first.inspectActivity(tool), isFalse);
    expect(targets.length, count);
    first.invalidate();
    active = true;
    expect(first.inspectActivity(tool), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    other.invalidate();
    await controller.close();
    await strategy.close();
    for (final registration in registrations) {
      await registration.close();
    }
    await runtime.close();
    expect(tester.takeException(), isNull);
  });
}

final class _Preparation implements ModelToolContribution {
  Completer<void> gate = Completer<void>();
  Completer<void> entered = Completer<void>();

  @override
  Future<Iterable<ToolRegistration>> materialize(
    ModelToolHostContext context,
  ) async {
    entered.complete();
    await gate.future;
    return const [];
  }
}

final class _Execution implements OrchestrationExecution {
  _Execution(this.host);
  final OrchestrationExecutionHost host;
  @override
  Future<void> start() async {
    host.start();
    final turn = await host.invokeModel(
      StrategyInferenceMaterial(input: const []),
    );
    if (turn.failure case final failure?) {
      host.fail(failure);
    } else {
      host.complete();
    }
  }

  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) =>
      throw StateError('No approvals');
  @override
  Future<void> close() async {}
}

final class _Channel implements AdeleStreamChannel {
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      {'providerState': <String, Object?>{}};
  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) async* {
    for (final output in [
      {'kind': 'text', 'text': 'Narration'},
      {
        'kind': 'toolProposal',
        'toolProposal': {
          'callId': 'call',
          'name': 'fixture_tool',
          'arguments': <String, Object?>{
            'nested': [1, true, null],
          },
        },
      },
      {
        'kind': 'nativeItem',
        'nativeMetadata': {
          'kind': 'fixture.raw',
          'compatibility': <String, Object?>{},
          'data': {'secret': 'secret-raw-envelope'},
        },
        'nativePresentation': {
          'kind': 'fixture.safe',
          'compactText': 'Safe native',
          'data': {'safe': true},
        },
      },
      {
        'kind': 'nativeItem',
        'nativeMetadata': {
          'kind': 'fixture.raw',
          'compatibility': <String, Object?>{},
          'data': {'secret': 'secret-raw-envelope'},
        },
      },
    ]) {
      yield {
        'kind': 'output',
        'observation': null,
        'terminal': null,
        'output': {
          'text': null,
          'toolProposal': null,
          'itemId': null,
          'nativeMetadata': null,
          'nativePresentation': null,
          ...output,
        },
      };
    }
    yield {
      'kind': 'terminal',
      'observation': null,
      'output': null,
      'terminal': {
        'settlement': 'completed',
        'incompleteReason': null,
        'failure': null,
        'providerStopReason': null,
        'usage': null,
        'effectiveModel': 'fixture',
        'responseId': null,
        'requestId': null,
        'nativeState': null,
      },
    };
  }
}
