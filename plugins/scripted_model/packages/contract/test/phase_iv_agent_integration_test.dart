import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/development/agent/agent_capability_adapters.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';
import 'package:scripted_model_contract/scripted_model_contract.dart';
import 'package:test/test.dart';

void main() {
  late String repository;
  late String dartaotruntime;
  late File hostArtifact;
  late File modelArtifact;
  late File basicArtifact;
  late File alternateArtifact;

  setUpAll(() async {
    repository = Directory.current.parent.parent.parent.parent.path;
    final Directory artifacts = Directory(
      '$repository/.dart_tool/adele/integration/phase-iv-agent',
    )..createSync(recursive: true);
    final String dart = Platform.resolvedExecutable;
    dartaotruntime = '${File(dart).parent.path}/dartaotruntime';
    expect(File(dartaotruntime).existsSync(), isTrue);
    hostArtifact = File('${artifacts.path}/host.aot');
    modelArtifact = File('${artifacts.path}/model.aot');
    basicArtifact = File('${artifacts.path}/basic.aot');
    alternateArtifact = File('${artifacts.path}/alternate.aot');
    await Future.wait(<Future<void>>[
      _compile(
        dart,
        '$repository/packages/plugin_backend_host/bin/adele_backend_host.dart',
        hostArtifact.path,
        repository,
      ),
      _compile(
        dart,
        '$repository/plugins/scripted_model/packages/backend/bin/scripted_model_backend.dart',
        modelArtifact.path,
        repository,
      ),
      _compile(
        dart,
        '$repository/plugins/resource_inspector/packages/basic_backend/bin/resource_inspector_basic_backend.dart',
        basicArtifact.path,
        repository,
      ),
      _compile(
        dart,
        '$repository/plugins/resource_inspector/packages/alternate_backend/bin/resource_inspector_alternate_backend.dart',
        alternateArtifact.path,
        repository,
      ),
    ]);
  });

  test(
    'executes deterministic generation-bound approval and failure vertical',
    () async {
      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
      );
      final int sharedProcessId = host.processId;
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final CapabilityRegistry registry = CapabilityRegistry();

      final _ActiveProvider model = await _startProvider(
        host: host,
        registry: registry,
        pluginId: 'dev.adele.scripted-model-plugin',
        artifact: modelArtifact,
        descriptor: ProviderDescriptor(
          id: scriptedModelProviderId,
          capability: agentModelCapability,
          pluginId: 'dev.adele.scripted-model-plugin',
          displayName: 'Scripted Model',
          serviceId: scriptedModelServiceId,
        ),
      );
      final _ActiveProvider basic = await _startProvider(
        host: host,
        registry: registry,
        pluginId: 'dev.adele.resource-inspector.basic-plugin',
        artifact: basicArtifact,
        descriptor: _inspectorDescriptor(
          basicResourceInspectorProviderId,
          'dev.adele.resource-inspector.basic-plugin',
          'Basic Inspector',
        ),
      );
      final _ActiveProvider alternate = await _startProvider(
        host: host,
        registry: registry,
        pluginId: 'dev.adele.resource-inspector.alternate-plugin',
        artifact: alternateArtifact,
        descriptor: _inspectorDescriptor(
          alternateResourceInspectorProviderId,
          'dev.adele.resource-inspector.alternate-plugin',
          'Alternate Inspector',
        ),
      );
      expect(host.processId, sharedProcessId);

      final CapabilityBackedAgentModel boundModel = CapabilityBackedAgentModel(
        registry.resolve(agentModelCapability),
      );
      final ResourceInspectorAgentTool boundTool = ResourceInspectorAgentTool(
        registry.resolve(
          resourceInspectCapability,
          providerId: basicResourceInspectorProviderId,
        ),
      );
      final AgentRun approved = AgentRun(
        userRequest: 'Inspect the Phase IV resource.',
        model: boundModel,
        tools: <AgentTool>[boundTool],
      );
      await approved.start();
      expect(approved.state, AgentRunState.awaitingApproval);
      expect(boundTool.invocationCount, 0);
      expect(approved.pendingApproval?.toolCallId, 'inspect-1');

      await approved.approve('inspect-1');

      expect(boundTool.invocationCount, 1);
      expect(approved.state, AgentRunState.completed);
      expect(approved.result, contains('Basic inspection'));
      expect(
        approved.events.map((AgentRunEvent event) => event.kind),
        <AgentRunEventKind>[
          AgentRunEventKind.runStarted,
          AgentRunEventKind.modelInvocationStarted,
          AgentRunEventKind.modelInvocationCompleted,
          AgentRunEventKind.toolCallProposed,
          AgentRunEventKind.toolCallApproved,
          AgentRunEventKind.toolExecutionStarted,
          AgentRunEventKind.toolExecutionCompleted,
          AgentRunEventKind.modelInvocationStarted,
          AgentRunEventKind.modelInvocationCompleted,
          AgentRunEventKind.runCompleted,
        ],
      );

      final ResourceInspectorAgentTool rejectedTool =
          ResourceInspectorAgentTool(
            registry.resolve(
              resourceInspectCapability,
              providerId: basicResourceInspectorProviderId,
            ),
          );
      final AgentRun rejected = AgentRun(
        userRequest: 'Reject this inspection.',
        model: CapabilityBackedAgentModel(
          registry.resolve(agentModelCapability),
        ),
        tools: <AgentTool>[rejectedTool],
      );
      await rejected.start();
      await rejected.reject('inspect-1');
      expect(rejectedTool.invocationCount, 0);
      expect(rejected.state, AgentRunState.completed);
      expect(rejected.result, contains('rejected'));

      final AgentRun staleModelRun = AgentRun(
        userRequest: 'Restart model before continuation.',
        model: CapabilityBackedAgentModel(
          registry.resolve(agentModelCapability),
        ),
        tools: <AgentTool>[
          ResourceInspectorAgentTool(
            registry.resolve(
              resourceInspectCapability,
              providerId: basicResourceInspectorProviderId,
            ),
          ),
        ],
      );
      await staleModelRun.start();
      await model.activation.close();
      final _ActiveProvider restartedModel = await _startProvider(
        host: host,
        registry: registry,
        pluginId: model.connection.pluginId,
        artifact: modelArtifact,
        descriptor: ProviderDescriptor(
          id: scriptedModelProviderId,
          capability: agentModelCapability,
          pluginId: model.connection.pluginId,
          displayName: 'Scripted Model',
          serviceId: scriptedModelServiceId,
        ),
      );
      await staleModelRun.approve('inspect-1');
      expect(staleModelRun.state, AgentRunState.failed);
      expect(
        staleModelRun.failure,
        isA<ProviderUnavailable>().having(
          (ProviderUnavailable error) => error.stale,
          'stale',
          isTrue,
        ),
      );

      final ResourceInspectorAgentTool staleTool = ResourceInspectorAgentTool(
        registry.resolve(
          resourceInspectCapability,
          providerId: basicResourceInspectorProviderId,
        ),
      );
      final AgentRun staleToolRun = AgentRun(
        userRequest: 'Restart tool before approval.',
        model: CapabilityBackedAgentModel(
          registry.resolve(agentModelCapability),
        ),
        tools: <AgentTool>[staleTool],
      );
      await staleToolRun.start();
      await basic.activation.close();
      final _ActiveProvider restartedBasic = await _startProvider(
        host: host,
        registry: registry,
        pluginId: basic.connection.pluginId,
        artifact: basicArtifact,
        descriptor: _inspectorDescriptor(
          basicResourceInspectorProviderId,
          basic.connection.pluginId,
          'Basic Inspector',
        ),
      );
      await staleToolRun.approve('inspect-1');
      expect(staleTool.invocationCount, 1);
      expect(staleToolRun.state, AgentRunState.failed);
      expect(staleToolRun.failure, isA<ProviderUnavailable>());

      final ResourceInspection unrelated = await ResourceInspectorServiceClient(
        registry
            .resolve(
              resourceInspectCapability,
              providerId: alternateResourceInspectorProviderId,
            )
            .requestChannel,
      ).inspect(ResourceRef(uri: Uri.parse('file:///tmp/unrelated.txt')));
      expect(unrelated.providerLabel, 'Alternate Inspector');
      final ScriptedModelResponse freshModelResponse =
          await ScriptedModelServiceClient(
            registry.resolve(agentModelCapability).requestChannel,
          ).invoke(
            const ScriptedModelRequest(
              messages: <ScriptedModelMessage>[
                ScriptedModelMessage(
                  role: ScriptedModelMessageRole.user,
                  content: 'fresh',
                  toolCallId: null,
                  toolOutcome: null,
                ),
              ],
              tools: <ScriptedToolDefinition>[
                ScriptedToolDefinition(
                  name: 'inspect_resource',
                  description: 'inspect',
                  argumentsSchema: <String, Object?>{},
                ),
              ],
            ),
          );
      expect(freshModelResponse.toolCall?.id, 'inspect-1');
      expect(host.processId, sharedProcessId);

      await restartedBasic.activation.close();
      await restartedModel.activation.close();
      await alternate.activation.close();
      expect(registry.providersFor(agentModelCapability), isEmpty);
      expect(registry.providersFor(resourceInspectCapability), isEmpty);
      await host.close();
      expect(host.isClosed, isTrue);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

ProviderDescriptor _inspectorDescriptor(
  ProviderId id,
  String pluginId,
  String displayName,
) => ProviderDescriptor(
  id: id,
  capability: resourceInspectCapability,
  pluginId: pluginId,
  displayName: displayName,
  serviceId: resourceInspectorServiceId,
);

Future<_ActiveProvider> _startProvider({
  required PluginBackendHost host,
  required CapabilityRegistry registry,
  required String pluginId,
  required File artifact,
  required ProviderDescriptor descriptor,
}) async {
  final PluginBackendConnection connection = await host.startPlugin(
    pluginId: pluginId,
    artifactUri: artifact.uri,
  );
  final PluginCapabilityActivation activation =
      await PluginCapabilityActivation.register(
        connection: connection,
        registry: registry,
        providers: <ProviderDescriptor>[descriptor],
      );
  return _ActiveProvider(connection: connection, activation: activation);
}

Future<void> _compile(
  String dart,
  String entrypoint,
  String output,
  String workingDirectory,
) async {
  final ProcessResult result = await Process.run(dart, <String>[
    'compile',
    'aot-snapshot',
    entrypoint,
    '-o',
    output,
  ], workingDirectory: workingDirectory);
  if (result.exitCode != 0) throw StateError(result.stderr.toString());
}

final class _ActiveProvider {
  const _ActiveProvider({required this.connection, required this.activation});

  final PluginBackendConnection connection;
  final PluginCapabilityActivation activation;
}
