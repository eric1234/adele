import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/frontend/session_execution_source.dart';
import 'package:adele_desktop/ui/execution/session_execution_controller.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
