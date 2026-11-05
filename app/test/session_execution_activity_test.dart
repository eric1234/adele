import 'dart:async';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/run_id_source.dart';
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

  for (final state in [RunState.created, RunState.running, RunState.waiting]) {
    test('recovered ${state.name} activity is historical, scoped and '
        'independent of execution availability', () async {
      final directory = Directory.systemTemp.createTempSync('activity-reopen-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final firstRuntime = AdeleRuntime();
      addTearDown(firstRuntime.close);
      final channel = _Channel();
      final projectProvider = ProviderId('fixture.project');
      void registerProject(AdeleRuntime runtime) {
        final registration = runtime.registry.register(
          provider: ProviderDescriptor(
            id: projectProvider,
            capability: projectProviderCapability,
            pluginId: 'dev.fixture',
            displayName: 'Project',
            serviceId: projectProviderServiceId,
          ),
          endpoint: AdeleRequestChannelEndpoint(
            channel: channel,
            serviceId: projectProviderServiceId,
            isAvailable: () => true,
          ),
        );
        addTearDown(registration.close);
      }

      registerProject(firstRuntime);
      final environment = firstRuntime.registry.register(
        provider: ProviderDescriptor(
          id: ProviderId('fixture.environment'),
          capability: environmentProviderCapability,
          pluginId: 'dev.fixture',
          displayName: 'Environment',
          serviceId: environmentProviderServiceId,
        ),
        endpoint: AdeleRequestChannelEndpoint(
          channel: channel,
          serviceId: environmentProviderServiceId,
          isAvailable: () => true,
        ),
      );
      addTearDown(environment.close);
      final strategyId = OrchestrationStrategyId('fixture.strategy');
      final strategy = firstRuntime.extensions.register(
        point: orchestrationStrategyContributions,
        id: ExtensionId('fixture.strategy'),
        value: OrchestrationStrategyContribution(
          strategyId: strategyId,
          materialize: (_) => throw StateError('Recovery must not execute.'),
        ),
      );
      addTearDown(strategy.close);
      final project = await firstRuntime.lifecycle.openProject(
        sourceLocation: directory.uri,
        provider: firstRuntime.lifecycle.resolveProjectProvider(
          projectProvider,
        ),
      );
      final task = await firstRuntime.lifecycle.createTask(
        projectId: project.id,
        title: 'Recovery',
      );
      final session = firstRuntime.lifecycle.createSession(
        taskId: task.task.id,
        strategyId: strategyId,
      );
      final foreign = firstRuntime.lifecycle.createSession(
        taskId: task.task.id,
        strategyId: strategyId,
      );
      final runId = RunId('interrupted');
      final snapshot = RunActivitySnapshot(
        runId: runId,
        sessionId: session.id,
        state: state,
        sequence: state == RunState.created
            ? 0
            : state == RunState.waiting
            ? 8
            : 7,
        lifecycle: [
          if (state != RunState.created)
            const RunLifecycleActivity(sequence: 1, state: RunState.running),
          if (state == RunState.waiting)
            const RunLifecycleActivity(sequence: 8, state: RunState.waiting),
        ],
        models: [
          if (state != RunState.created)
            ModelInvocationActivity(
              id: ModelInvocationId('original-model'),
              startSequence: 2,
              outputs: [
                ModelOutputActivity(
                  sequence: 4,
                  item: ModelTextOutput('Recorded partial text'),
                ),
                ModelOutputActivity(
                  sequence: 7,
                  item: ModelToolProposalOutput(
                    ProviderToolProposal(
                      providerCallId: 'original-call',
                      alias: 'unresolved_tool',
                      arguments: const {'value': 42},
                    ),
                  ),
                ),
              ],
            ),
        ],
      );
      firstRuntime.lifecycle.checkpointRunActivity(session, snapshot);
      // An in-process checkpoint is not eligible recovered history.
      expect(firstRuntime.lifecycle.recoveredRun(runId), isNull);
      await firstRuntime.close();

      final runtime = AdeleRuntime();
      addTearDown(runtime.close);
      registerProject(runtime);
      await runtime.lifecycle.openProject(
        sourceLocation: directory.uri,
        provider: runtime.lifecycle.resolveProjectProvider(projectProvider),
      );
      final restored = runtime.store.session(session.id)!;
      final recovered = runtime.lifecycle.recoveredRun(runId)!;
      expect(recovered.session, same(restored));
      expect(recovered.status, RecoveredRunStatus.interrupted);
      expect(recovered.terminalRecord, isNull);
      final controller = SessionExecutionController(
        runtime: runtime,
        session: restored,
        providerId: ProviderId('missing.model'),
        model: 'fixture',
        runIds: _RepeatedRunId(runId),
      );
      addTearDown(controller.close);
      final otherController = SessionExecutionController(
        runtime: runtime,
        session: runtime.store.session(foreign.id)!,
        providerId: ProviderId('missing.model'),
        model: null,
      );
      addTearDown(otherController.close);
      expect(
        () => SessionExecutionController(
          runtime: runtime,
          session: Session(
            id: restored.id,
            taskId: restored.taskId,
            strategyId: restored.strategyId,
          ),
          providerId: controller.providerId,
          model: null,
        ),
        throwsArgumentError,
      );
      var active = true;
      final inspection = WindowInspection()..presentSession(restored);
      addTearDown(inspection.dispose);
      SessionExecutionPresentationSource source() =>
          SessionExecutionPresentationSource(
            controller: controller,
            extensions: runtime.extensions,
            isActive: () => active,
            inspect: (canonical, target) {
              expect(canonical, same(restored));
              final activity = controller.activityForRun(target.runId)!;
              final status = controller.activityStatusForRun(target.runId)!;
              return switch (target) {
                ActivityGroupInspectionTarget() => inspection.inspectActivity(
                  session: canonical,
                  activity: activity,
                  modelInvocationId: target.modelInvocationId,
                  status: status,
                ),
                ModelOutputInspectionTarget() => inspection.inspectOutput(
                  session: canonical,
                  activity: activity,
                  modelInvocationId: target.modelInvocationId,
                  outputSequence: target.outputSequence,
                  status: status,
                ),
              };
            },
          );
      final view = source();
      addTearDown(view.invalidate);
      expect(controller.activityForRun(runId), same(recovered.activity));
      expect(controller.activitySnapshots, [same(recovered.activity)]);
      expect(
        controller.activityStatusForRun(runId),
        SessionRunActivityStatus.interrupted,
      );
      expect(controller.stateForRun(runId), isNull);
      expect(controller.ownsScheduledRun(runId), isFalse);
      expect(otherController.activityForRun(runId), isNull);
      expect(otherController.activityStatusForRun(runId), isNull);
      for (final invalid in ['', ' interrupted', 'interrupted ', 'unknown']) {
        expect(view.openRunActivity(invalid), isNull);
      }
      final handle = view.openRunActivity(runId.value)!;
      final data = view.readRunActivity(handle);
      expect(data['status'], 'interrupted');
      expect(data['state'], state.name);
      expect(controller.currentRun, isNull);
      expect(controller.latestRunId, isNull);
      expect(controller.pendingApproval, isNull);
      expect(controller.isRunning, isFalse);
      expect(controller.isAdvancing, isFalse);
      expect(controller.canStart, isFalse, reason: 'No executable providers.');
      expect(runtime.lifecycle.hasSessionExecution(restored), isFalse);
      expect(
        runtime.lifecycle.environmentRuntime.currentMaterialization(
          runtime.store.requireSessionAuthority(restored.id).environmentId,
        ),
        isNull,
      );
      if (state != RunState.created) {
        final model = (data['models']! as List).single as Map;
        expect(model['sequence'], 2);
        expect(model['settlement'], isNull);
        expect(model['failure'], isNull);
        final outputs = model['outputs'] as List;
        expect(outputs.map((output) => (output as Map)['sequence']), [4, 7]);
        expect((outputs.first as Map)['content'], 'Recorded partial text');
        final proposal = outputs.last as Map;
        expect(proposal['arguments'], {'value': 42});
        expect(proposal['tool'], isNull);
        expect(proposal['rejection'], isNull);
        final outputHandle = proposal['handle'] as String;
        expect(view.inspectActivity(outputHandle), isTrue);
        final inspected =
            inspection.cards.single.target as ModelOutputInspectionTarget;
        expect(inspected.modelInvocationId.value, 'original-model');
        expect(inspected.outputSequence, 7);
      }
      active = false;
      expect(() => view.readRunActivity(handle), throwsStateError);
      active = true;
      expect(() => view.openRunActivity(runId.value), throwsStateError);
      final replacement = source();
      addTearDown(replacement.invalidate);
      final freshHandle = replacement.openRunActivity(runId.value)!;
      expect(freshHandle, isNot(handle));
      expect(() => replacement.readRunActivity(handle), throwsStateError);
      final freshData = replacement.readRunActivity(freshHandle);
      expect(freshData['status'], 'interrupted');

      final freshStrategy = runtime.extensions.register(
        point: orchestrationStrategyContributions,
        id: ExtensionId('fixture.strategy'),
        value: OrchestrationStrategyContribution(
          strategyId: strategyId,
          materialize: (_) =>
              throw StateError('Must not reuse historical Run.'),
        ),
      );
      addTearDown(freshStrategy.close);
      final freshProvider = runtime.registry.register(
        provider: ProviderDescriptor(
          id: controller.providerId,
          capability: modelProviderCapability,
          pluginId: 'dev.fixture',
          displayName: 'Model',
          serviceId: modelProviderServiceId,
        ),
        endpoint: AdeleRequestChannelEndpoint(
          channel: channel,
          serviceId: modelProviderServiceId,
          isAvailable: () => true,
        ),
      );
      addTearDown(freshProvider.close);
      expect(
        controller.canStart,
        isTrue,
        reason: 'History does not occupy a Run slot.',
      );
      await expectLater(controller.startRun(), throwsStateError);
      expect(controller.currentRun, isNull);
      expect(controller.canStart, isTrue);
      expect(replacement.readRunActivity(freshHandle), freshData);
      expect(controller.activityForRun(runId), same(recovered.activity));
    });
  }

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
      expect(data['status'], 'terminal');
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
      final reopened = SessionExecutionPresentationSource(
        controller: controller,
        extensions: runtime.extensions,
        isActive: () => true,
        inspect: (_, _) => false,
      );
      final foreignSession = runtime.lifecycle.createSession(
        taskId: task.task.id,
        strategyId: strategyId,
      );
      final foreignController = SessionExecutionController(
        runtime: runtime,
        session: foreignSession,
        providerId: providerId,
        model: 'fixture',
      );
      final foreign = SessionExecutionPresentationSource(
        controller: foreignController,
        extensions: runtime.extensions,
        isActive: () => true,
        inspect: (_, _) => false,
      );
      addTearDown(() async {
        if (!preparation.gate.isCompleted) preparation.gate.complete();
        source.invalidate();
        reopened.invalidate();
        foreign.invalidate();
        await foreignController.close();
        await controller.close();
        await tools.close();
        await strategy.close();
        for (final provider in providers) {
          await provider.close();
        }
        await runtime.close();
      });

      final failedHandle = await source.startRun();
      final failedId = controller.latestRunId!;
      final failedAdvance = controller.activeRunFuture!;
      await preparation.entered.future;
      expect(source.readRunActivity(failedHandle)['state'], 'created');
      expect(source.readRunActivity(failedHandle)['status'], 'live');
      final reopenedHandle = reopened.openRunActivity(failedId.value)!;
      expect(reopenedHandle, isNot(failedHandle));
      expect(reopened.readRunActivity(reopenedHandle)['state'], 'created');
      expect(reopened.readRunActivity(reopenedHandle)['models'], isEmpty);
      expect(foreign.openRunActivity(failedId.value), isNull);
      expect(controller.currentRun, isNull);
      preparation.gate.completeError(StateError('Tool preparation failed.'));
      await failedAdvance;
      final failed = source.readRunActivity(failedHandle);
      expect(failed['state'], 'failed');
      expect(failed['status'], 'live');
      expect(failed['models'], isEmpty);
      expect(reopened.readRunActivity(reopenedHandle)['state'], 'failed');
      expect(foreign.openRunActivity(failedId.value), isNull);
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
      expect(source.readRunActivity(retryHandle)['status'], 'terminal');
      expect(source.readRunActivity(failedHandle), failed);
      expect(reopened.openRunActivity(failedId.value), reopenedHandle);
      expect(reopened.readRunActivity(reopenedHandle)['state'], 'failed');
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
    expect(
      first.inspectActivity(tool),
      isFalse,
      reason: 'An observed retired presentation never revives.',
    );
    expect(() => first.openRunActivity(run.id.value), throwsStateError);
    final freshHandle = other.openRunActivity(run.id.value)!;
    final freshData = other.readRunActivity(freshHandle);
    final freshModel = (freshData['models']! as List).single as Map;
    final freshSafe =
        ((freshModel['outputs']! as List)[2] as Map)['handle']! as String;
    expect(freshHandle, isNot(handle));
    expect(freshSafe, isNot(safe));
    final cached = other.buildActivity(freshSafe);
    other.retainPresentation();
    await controller.close();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: cached)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Safe native'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: other.buildActivity(freshSafe))),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Safe native'), findsOneWidget);
    tester.widget<TextButton>(find.byType(TextButton).first).onPressed?.call();
    expect(other.inspectActivity(freshSafe), isFalse);
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
      method == projectProviderServicePrepareSourceId
      ? {
          'sourceLocation': payload['sourceLocation'],
          'databaseRelativePath': '.adele/data.db',
        }
      : {'providerState': <String, Object?>{}, 'initialState': null};
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
        'affinityState': null,
      },
    };
  }
}

final class _RepeatedRunId implements RunIdSource {
  _RepeatedRunId(this.id);
  final RunId id;
  @override
  RunId nextRunId() => id;
}
