import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart'
    show modelProviderCapability;
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

void main() {
  test('startup only composes six stock contributions and a shared graph', () {
    final _RecordingIds ids = _RecordingIds();
    final AdeleRuntime runtime = AdeleRuntime(ids: ids);
    addTearDown(runtime.close);

    expect(ids.calls, isEmpty);
    expect(
      runtime.registry.providersFor(environmentProviderCapability),
      isEmpty,
    );
    expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
    expect(runtime.store.project(ProjectId('project-1')), isNull);
    expect(runtime.store.tasksFor(ProjectId('project-1')), isEmpty);
    expect(runtime.store.task(TaskId('task-1')), isNull);
    expect(runtime.store.environment(EnvironmentId('environment-1')), isNull);
    expect(runtime.store.session(SessionId('session-1')), isNull);
    expect(runtime.store.sessionAuthority(SessionId('session-1')), isNull);
    expect(runtime.lifecycle.store, same(runtime.store));
    expect(runtime.lifecycle.environmentRuntime.store, same(runtime.store));
    expect(
      runtime.lifecycle.environmentRuntime.currentMaterialization(
        EnvironmentId('environment-1'),
      ),
      isNull,
    );
    expect(
      _contributions(runtime).map((binding) => binding.id.value),
      unorderedEquals(<String>[
        'dev.adele.plugin.chat-strategy.orchestration',
        'dev.adele.plugin.agents-md.instructions',
        'dev.adele.plugin.filesystem-tools.model-tools',
        'dev.adele.plugin.search-tools.model-tools',
        'dev.adele.plugin.command-tools.model-tools',
        'dev.adele.plugin.local-directory-project-selector.project-selector',
      ]),
    );
    expect(
      runtime.extensions
          .discover(projectSelectorContributions)
          .single
          .value
          .displayName,
      'Open Local Directory...',
    );
    expect(
      runtime.lifecycle.strategyResolver.resolve(chatStrategyId).contribution,
      same(
        runtime.extensions
            .discover(orchestrationStrategyContributions)
            .single
            .value,
      ),
    );
  });

  test(
    'default IDs are optional and reduced composition omits only commands',
    () {
      final AdeleRuntime runtime = AdeleRuntime(includeCommandTools: false);
      addTearDown(runtime.close);

      expect(
        _contributions(runtime).map((binding) => binding.id.value),
        unorderedEquals(<String>[
          'dev.adele.plugin.chat-strategy.orchestration',
          'dev.adele.plugin.agents-md.instructions',
          'dev.adele.plugin.filesystem-tools.model-tools',
          'dev.adele.plugin.search-tools.model-tools',
          'dev.adele.plugin.local-directory-project-selector.project-selector',
        ]),
      );
      final Project project = runtime.lifecycle.createProject(
        Uri.parse('file:///runtime-fixture/source'),
      );
      expect(runtime.store.project(project.id), same(project));
    },
  );

  test(
    'later generated provider powers retained Chat, AGENTS and retired tools',
    () async {
      final _RecordingIds ids = _RecordingIds();
      final AdeleRuntime runtime = AdeleRuntime(ids: ids);
      addTearDown(runtime.close);
      final _EnvironmentChannel channel = _EnvironmentChannel();
      final ProviderId providerId = ProviderId(
        'dev.adele.environment.runtime-test',
      );
      final CapabilityRegistration provider = runtime.registry.register(
        provider: ProviderDescriptor(
          id: providerId,
          capability: environmentProviderCapability,
          pluginId: 'dev.adele.plugin.runtime-test',
          displayName: 'Runtime Test',
          serviceId: environmentProviderServiceId,
        ),
        endpoint: AdeleRequestChannelEndpoint(
          channel: channel,
          serviceId: environmentProviderServiceId,
          isAvailable: () => true,
        ),
      );
      addTearDown(provider.close);
      expect(channel.calls, isEmpty);
      expect(ids.calls, isEmpty);

      final Project project = runtime.lifecycle.createProject(
        Uri.parse('file:///runtime-fixture/source'),
      );
      final TaskCreationResult created = await runtime.lifecycle.createTask(
        projectId: project.id,
        title: 'Runtime composition',
        providerId: providerId,
      );
      final Session session = runtime.lifecycle.createSession(
        taskId: created.task.id,
        strategyId: chatStrategyId,
      );
      expect(ids.calls, <String>['project', 'task', 'environment', 'session']);
      expect(runtime.store.project(project.id), same(project));
      expect(runtime.store.task(created.task.id), same(created.task));
      expect(
        runtime.store.environment(created.environment.id),
        same(created.environment),
      );
      expect(runtime.store.session(session.id), same(session));
      expect(
        runtime.store.requireSessionAuthority(session.id).environmentId,
        created.environment.id,
      );
      final EnvironmentMaterialization materialization = await runtime
          .lifecycle
          .environmentRuntime
          .materialize(created.environment.id);
      expect(materialization.environment, same(created.environment));
      expect(materialization.provider, isA<GeneratedEnvironmentProvider>());
      final Map<String, Object?> context =
          channel.calls.single.payload['context']! as Map<String, Object?>;
      expect(
        channel.calls.single.method,
        environmentProviderServiceEstablishId,
      );
      expect(context['projectId'], project.id.value);
      expect(context['taskId'], session.taskId.value);
      expect(context['environmentId'], created.environment.id.value);
      expect(context['providerId'], providerId.value);

      final ChatSessionState history = runtime.chat.sessions.obtain(session.id)
        ..instructions = 'Runtime-owned Chat instructions.'
        ..append(ChatUserMessage('Retained question.'))
        ..append(ChatAssistantMessage('Retained answer.'))
        ..append(ChatUserMessage('Current question.'));
      final ToolCatalog catalog = await buildModelToolCatalogForSession(
        sessionId: session.id,
        environmentRuntime: runtime.lifecycle.environmentRuntime,
        extensions: runtime.extensions,
      );
      final _RecordingModel model = _RecordingModel();
      final SessionOrchestrationRun run = createSessionOrchestrationRun(
        lifecycle: runtime.lifecycle,
        sessionId: session.id,
        runId: RunId('runtime-run'),
        contextComposer: runtime.contextComposer,
        model: model,
        toolCatalog: catalog,
        policy: const _NoToolCalls(),
      );
      expect(model.requests, isEmpty);
      expect(channel.calls, hasLength(1));

      await run.start();

      expect(run.run.state, RunState.completed);
      final SemanticModelRequest request = model.requests.single;
      expect(
        request.input.map(
          (item) => ((item as SemanticMessageInput).role, item.content),
        ),
        <(SemanticMessageRole, String)>[
          (SemanticMessageRole.user, 'Retained question.'),
          (SemanticMessageRole.assistant, 'Retained answer.'),
          (SemanticMessageRole.user, 'Current question.'),
        ],
      );
      expect(runtime.chat.sessions.obtain(session.id), same(history));
      expect(history.snapshot().entries.map((entry) => entry.content), <String>[
        'Retained question.',
        'Retained answer.',
        'Current question.',
        'Runtime answer.',
      ]);
      expect(history.snapshot().entries.last, isA<ChatAssistantMessage>());
      expect(
        (request.context.instructionGroups.first as StrategyInstructionGroup)
            .instructions,
        history.instructions,
      );
      final InferenceContextSourceResult source =
          request.context.sourceResults.single;
      expect(source.sourceId.value, 'dev.adele.plugin.agents-md.instructions');
      expect(source.failureMode, InferenceContextFailureMode.required);
      expect(source.status, InferenceContextSourceStatus.contributed);
      final InferenceInstructionMaterial agents = source.materials.singleWhere(
        (material) => material.key == 'AGENTS.md',
      );
      expect(agents.text, _EnvironmentChannel.agentsText);
      expect(agents.revision, 'agents-revision');
      expect(channel.calls, hasLength(2));
      expect(channel.calls.last.method, environmentProviderServiceReadFileId);
      expect(channel.calls.last.payload, <String, Object?>{
        'environmentId': created.environment.id.value,
        'relativePath': 'AGENTS.md',
      });
      expect(
        request.tools.tools.map((tool) => tool.modelDefinition.alias),
        unorderedEquals(<String>[
          'read_file',
          'apply_patch',
          'create_file',
          'delete_file',
          'search',
          'run_command',
        ]),
      );
      for (final MaterializedTool tool in request.tools.tools) {
        tool.executable.validateBinding();
      }
      final List<ExtensionBinding<Object>> bindings = _contributions(runtime);
      final ResolvedOrchestrationStrategy strategy = runtime.lifecycle
          .resolveSessionStrategy(session.id);

      final Future<void> closing = runtime.close();
      expect(runtime.close(), same(closing));
      await closing;
      expect(runtime.close(), same(closing));

      expect(_contributions(runtime), isEmpty);
      for (final ExtensionBinding<Object> binding in bindings) {
        expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
      }
      expect(strategy.validateBinding, throwsA(isA<StaleExtensionBinding>()));
      expect(
        () => runtime.lifecycle.resolveSessionStrategy(session.id),
        throwsA(isA<OrchestrationStrategyUnavailable>()),
      );
      for (final MaterializedTool tool in request.tools.tools) {
        expect(
          tool.executable.validateBinding,
          throwsA(isA<StaleToolBindingException>()),
        );
      }
      // The caller owns provider registration; runtime closes only its extensions.
      expect(provider.isClosed, isFalse);
      materialization.validateBinding();
      expect(channel.calls, hasLength(2));
    },
  );
}

List<ExtensionBinding<Object>> _contributions(AdeleRuntime runtime) => [
  ...runtime.extensions.discover(orchestrationStrategyContributions),
  ...runtime.extensions.discover(inferenceContextSources),
  ...runtime.extensions.discover(modelToolContributions),
  ...runtime.extensions.discover(projectSelectorContributions),
];

final class _RecordingIds implements ProductIdSource {
  final List<String> calls = <String>[];

  @override
  ProjectId nextProjectId() {
    calls.add('project');
    return ProjectId('project-1');
  }

  @override
  TaskId nextTaskId() {
    calls.add('task');
    return TaskId('task-1');
  }

  @override
  EnvironmentId nextEnvironmentId() {
    calls.add('environment');
    return EnvironmentId('environment-1');
  }

  @override
  SessionId nextSessionId() {
    calls.add('session');
    return SessionId('session-1');
  }
}

final class _EnvironmentChannel implements AdeleRequestChannel {
  static const String agentsText = 'Use the Session Environment.\n';
  final List<({String method, Map<String, Object?> payload})> calls = [];

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    calls.add((method: method, payload: payload));
    return switch (method) {
      environmentProviderServiceEstablishId => <String, Object?>{
        'providerState': <String, Object?>{'transport': 'established'},
      },
      environmentProviderServiceReadFileId => <String, Object?>{
        'relativePath': payload['relativePath'],
        'text': agentsText,
        'sizeBytes': agentsText.length,
        'revision': 'agents-revision',
      },
      _ => throw StateError('Unexpected Environment operation: $method'),
    };
  }
}

final class _RecordingModel implements ModelPort {
  final List<SemanticModelRequest> requests = <SemanticModelRequest>[];

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    requests.add(request);
    yield ModelOutputItemCompleted(
      invocationId: request.invocationId,
      item: ModelTextOutput('Runtime answer.'),
    );
    yield ModelInvocationSettledEvent(
      invocationId: request.invocationId,
      settlement: ModelSettlement.completed,
      metadata: ModelTerminalMetadata(effectiveModel: 'runtime-fixture'),
    );
  }
}

final class _NoToolCalls implements ToolPolicy {
  const _NoToolCalls();

  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) =>
      throw StateError('This Run must not execute tools.');
}
