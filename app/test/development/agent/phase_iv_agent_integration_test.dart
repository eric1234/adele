import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/development/agent/agent_capability_adapters.dart';
import 'package:adele_desktop/development/agent/development_agent_support.dart';
import 'package:adele_desktop/development/agent/simple_tool_loop_strategy.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';
import 'package:scripted_model_contract/scripted_model_contract.dart';

void main() {
  late String repository;
  late String dartaotruntime;
  late File hostArtifact;
  late File modelArtifact;
  late File basicArtifact;
  late File alternateArtifact;

  setUpAll(() async {
    repository = Directory.current.parent.path;
    final Directory artifacts = Directory(
      '$repository/.dart_tool/adele/integration/phase-iv-a-agent',
    )..createSync(recursive: true);
    final String dart = _dartExecutable();
    dartaotruntime =
        '${File(dart).parent.path}/${Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime'}';
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
        '$repository/plugins/scripted_model/packages/backend/bin/scripted_model_provider_backend.dart',
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
    'runs the Phase IV-A semantic vertical through generation-bound AOT providers',
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

      final _ActiveProvider modelA = await _startProvider(
        host: host,
        registry: registry,
        pluginId: 'dev.adele.scripted-model-fixture-plugin',
        artifact: modelArtifact,
        descriptor: _modelDescriptor('dev.adele.scripted-model-fixture-plugin'),
      );
      final _ActiveProvider basicA = await _startProvider(
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

      final ModelProviderCapabilityAdapter happyModel =
          ModelProviderCapabilityAdapter(
            registry.resolve(modelProviderCapability),
            selectedModel: 'scripted-v1',
          );
      final ResourceInspectorToolExecutable happyTool =
          ResourceInspectorToolExecutable(
            registry.resolve(
              resourceInspectCapability,
              providerId: basicResourceInspectorProviderId,
            ),
          );
      final _RunFixture happy = _runFixture(
        id: 'happy',
        userContent: 'Inspect the Phase IV resource.',
        model: happyModel,
        registration: happyTool.registration,
      );

      await happy.strategy.start();

      expect(happy.run.state, RunState.waiting);
      expect(happyTool.invocationCount, 0);
      final ToolApprovalInterruption happyApproval =
          happy.run.interruptions.values.single as ToolApprovalInterruption;
      expect(happyApproval.toolId, resourceInspectionToolId);
      expect(happyApproval.canonicalArguments, const <String, Object?>{
        'uri': 'file:///tmp/adele-phase-iv.txt',
      });
      expect(happyApproval.effects.targets.single.uri.isAbsolute, isTrue);

      await happy.strategy.resolveApproval(
        ToolApprovalResolution(
          interruptionId: happyApproval.id,
          toolInvocationId: happyApproval.toolInvocationId,
          approved: true,
        ),
      );

      expect(happy.run.state, RunState.completed);
      expect(happyTool.invocationCount, 1);
      expect(happyModel.invocationCount, 2);
      expect(modelA.streamCount, 2);
      expect(modelA.requestCount, 0);
      expect(happy.session.snapshot().entries, <Matcher>[
        isA<UserSessionMessage>(),
        isA<AssistantSessionMessage>().having(
          (AssistantSessionMessage message) => message.content,
          'content',
          contains('Basic inspection'),
        ),
      ]);
      final ToolOutcome happyOutcome = happy.strategy.lastToolOutcome!;
      expect(happyOutcome.modelContent, contains('Basic inspection'));
      expect(happyOutcome.hostData['providerLabel'], 'Basic Inspector');
      expect(
        happyOutcome.hostData['resource'],
        isA<Map<String, Object?>>().having(
          (Map<String, Object?> resource) => resource['uri'],
          'uri',
          'file:///tmp/adele-phase-iv.txt',
        ),
      );
      expect(
        happy.strategy.lastToolInvocation!.tool.definition.id,
        resourceInspectionToolId,
      );
      expect(
        happy.strategy.lastToolInvocation!.tool.modelDefinition.alias,
        'inspect_resource',
      );
      expect(
        happy.run.journal.records.map(
          (ExecutionEventRecord record) => record.event.runtimeType,
        ),
        <Type>[
          RunStarted,
          ModelInvocationStarted,
          ModelObservationObserved,
          ModelOutputObserved,
          ModelOutputObserved,
          ModelInvocationSettled,
          ToolInvocationPrepared,
          ToolPolicyEvaluated,
          RunInterrupted,
          RunWaiting,
          RunInterruptionResolved,
          RunResumed,
          ToolExecutionStarted,
          ToolExecutionCompleted,
          ModelInvocationStarted,
          ModelObservationObserved,
          ModelOutputObserved,
          ModelInvocationSettled,
          RunCompleted,
        ],
      );

      final ResourceInspectorToolExecutable rejectedTool =
          ResourceInspectorToolExecutable(
            registry.resolve(
              resourceInspectCapability,
              providerId: basicResourceInspectorProviderId,
            ),
          );
      final _RunFixture rejected = _runFixture(
        id: 'rejected',
        userContent: 'Reject the inspection.',
        model: ModelProviderCapabilityAdapter(
          registry.resolve(modelProviderCapability),
          selectedModel: 'scripted-v1',
        ),
        registration: rejectedTool.registration,
      );
      await rejected.strategy.start();
      final ToolApprovalInterruption rejectedApproval =
          rejected.run.interruptions.values.single as ToolApprovalInterruption;
      await rejected.strategy.resolveApproval(
        ToolApprovalResolution(
          interruptionId: rejectedApproval.id,
          toolInvocationId: rejectedApproval.toolInvocationId,
          approved: false,
        ),
      );
      expect(rejected.run.state, RunState.completed);
      expect(rejectedTool.invocationCount, 0);
      expect(
        rejected.strategy.lastToolOutcome?.disposition,
        ToolOutcomeDisposition.userRejected,
      );
      expect(
        (rejected.session.snapshot().entries.last as AssistantSessionMessage)
            .content,
        contains('rejected'),
      );
      expect(
        rejected.run.journal.records
            .map((ExecutionEventRecord record) => record.event)
            .whereType<ToolExecutionStarted>(),
        isEmpty,
      );
      expect(
        rejected.run.journal.records
            .map((ExecutionEventRecord record) => record.event)
            .whereType<ToolExecutionCompleted>(),
        isEmpty,
      );
      expect(
        rejected.run.journal.records
            .map((ExecutionEventRecord record) => record.event)
            .whereType<ToolInvocationCompleted>(),
        hasLength(1),
      );

      final ResourceInspectorToolExecutable staleTool =
          ResourceInspectorToolExecutable(
            registry.resolve(
              resourceInspectCapability,
              providerId: basicResourceInspectorProviderId,
            ),
          );
      final _RunFixture staleToolRun = _runFixture(
        id: 'stale-tool',
        userContent: 'Restart the tool before approval.',
        model: ModelProviderCapabilityAdapter(
          registry.resolve(modelProviderCapability),
          selectedModel: 'scripted-v1',
        ),
        registration: staleTool.registration,
      );
      await staleToolRun.strategy.start();
      final ToolApprovalInterruption staleToolApproval =
          staleToolRun.run.interruptions.values.single
              as ToolApprovalInterruption;
      await basicA.activation.close();
      final _ActiveProvider basicB = await _startProvider(
        host: host,
        registry: registry,
        pluginId: basicA.connection.pluginId,
        artifact: basicArtifact,
        descriptor: _inspectorDescriptor(
          basicResourceInspectorProviderId,
          basicA.connection.pluginId,
          'Basic Inspector',
        ),
      );
      final ResourceInspectorToolExecutable replacementTool =
          ResourceInspectorToolExecutable(
            registry.resolve(
              resourceInspectCapability,
              providerId: basicResourceInspectorProviderId,
            ),
          );
      await staleToolRun.strategy.resolveApproval(
        ToolApprovalResolution(
          interruptionId: staleToolApproval.id,
          toolInvocationId: staleToolApproval.toolInvocationId,
          approved: true,
        ),
      );
      expect(staleToolRun.run.state, RunState.completed);
      expect(staleTool.invocationCount, 0);
      expect(replacementTool.invocationCount, 0);
      expect(basicB.requestCount, 0);
      expect(
        staleToolRun.strategy.lastToolOutcome?.failureKind,
        ToolFailureKind.staleBinding,
      );
      expect(
        staleToolRun.strategy.lastToolOutcome?.effectCertainty,
        EffectCertainty.knownNotOccurred,
      );

      late _ActiveProvider modelB;
      late ModelProviderCapabilityAdapter replacementModel;
      final ModelProviderCapabilityAdapter staleModel =
          ModelProviderCapabilityAdapter(
            registry.resolve(modelProviderCapability),
            selectedModel: 'scripted-v1',
          );
      final ResourceInspectorToolExecutable modelRestartTool =
          ResourceInspectorToolExecutable(
            registry.resolve(
              resourceInspectCapability,
              providerId: basicResourceInspectorProviderId,
            ),
          );
      final _AfterToolExecutable closeModelAfterTool = _AfterToolExecutable(
        delegate: modelRestartTool,
        afterTerminal: () async {
          await modelA.activation.close();
          modelB = await _startProvider(
            host: host,
            registry: registry,
            pluginId: modelA.connection.pluginId,
            artifact: modelArtifact,
            descriptor: _modelDescriptor(modelA.connection.pluginId),
          );
          replacementModel = ModelProviderCapabilityAdapter(
            registry.resolve(modelProviderCapability),
            selectedModel: 'scripted-v1',
          );
        },
      );
      final ToolRegistration modelRestartRegistration = _replaceExecutable(
        modelRestartTool.registration,
        closeModelAfterTool,
      );
      final _RunFixture staleModelRun = _runFixture(
        id: 'stale-model',
        userContent: 'Restart the model after tool completion.',
        model: staleModel,
        registration: modelRestartRegistration,
      );
      await staleModelRun.strategy.start();
      final ToolApprovalInterruption staleModelApproval =
          staleModelRun.run.interruptions.values.single
              as ToolApprovalInterruption;
      await staleModelRun.strategy.resolveApproval(
        ToolApprovalResolution(
          interruptionId: staleModelApproval.id,
          toolInvocationId: staleModelApproval.toolInvocationId,
          approved: true,
        ),
      );
      expect(modelRestartTool.invocationCount, 1);
      expect(staleModel.invocationCount, 1);
      expect(replacementModel.invocationCount, 0);
      expect(modelB.requestCount, 0);
      expect(modelB.streamCount, 0);
      expect(staleModelRun.run.state, RunState.failed);
      expect(
        staleModelRun.run.failure,
        isA<ProviderUnavailable>().having(
          (ProviderUnavailable error) => error.stale,
          'stale',
          isTrue,
        ),
      );
      expect(
        staleModelRun.run.journal.records
            .map((ExecutionEventRecord record) => record.event)
            .whereType<ModelInvocationFailed>(),
        hasLength(1),
      );

      final _RunFixture fresh = _runFixture(
        id: 'fresh',
        userContent: 'Use restarted provider generations.',
        model: replacementModel,
        registration: replacementTool.registration,
      );
      await fresh.strategy.start();
      final ToolApprovalInterruption freshApproval =
          fresh.run.interruptions.values.single as ToolApprovalInterruption;
      await fresh.strategy.resolveApproval(
        ToolApprovalResolution(
          interruptionId: freshApproval.id,
          toolInvocationId: freshApproval.toolInvocationId,
          approved: true,
        ),
      );
      expect(fresh.run.state, RunState.completed);
      expect(replacementModel.invocationCount, 2);
      expect(replacementTool.invocationCount, 1);

      final ResourceInspectorToolExecutable failingTool =
          ResourceInspectorToolExecutable(
            registry.resolve(
              resourceInspectCapability,
              providerId: basicResourceInspectorProviderId,
            ),
          );
      final _RunFixture containedFailure = _runFixture(
        id: 'contained-failure',
        userContent: 'fixture:tool-domain-failure',
        model: ModelProviderCapabilityAdapter(
          registry.resolve(modelProviderCapability),
          selectedModel: 'scripted-v1',
        ),
        registration: failingTool.registration,
      );
      await containedFailure.strategy.start();
      final ToolApprovalInterruption failureApproval =
          containedFailure.run.interruptions.values.single
              as ToolApprovalInterruption;
      await containedFailure.strategy.resolveApproval(
        ToolApprovalResolution(
          interruptionId: failureApproval.id,
          toolInvocationId: failureApproval.toolInvocationId,
          approved: true,
        ),
      );
      expect(containedFailure.run.state, RunState.completed);
      expect(
        containedFailure.strategy.lastToolOutcome?.failureKind,
        ToolFailureKind.domain,
      );
      expect(
        containedFailure.strategy.lastToolOutcome?.effectCertainty,
        EffectCertainty.uncertain,
      );
      expect(registry.providersFor(modelProviderCapability), hasLength(1));
      expect(registry.providersFor(resourceInspectCapability), hasLength(2));
      final ResourceInspection unrelated = await ResourceInspectorServiceClient(
        registry
            .resolve(
              resourceInspectCapability,
              providerId: alternateResourceInspectorProviderId,
            )
            .requestChannel,
      ).inspect(ResourceRef(uri: Uri.parse('file:///tmp/unrelated.txt')));
      expect(unrelated.providerLabel, 'Alternate Inspector');
      expect(host.processId, sharedProcessId);

      await basicB.activation.close();
      await modelB.activation.close();
      await alternate.activation.close();
      expect(registry.providersFor(modelProviderCapability), isEmpty);
      expect(registry.providersFor(resourceInspectCapability), isEmpty);
      await host.close();
      expect(host.isClosed, isTrue);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

_RunFixture _runFixture({
  required String id,
  required String userContent,
  required ModelPort model,
  required ToolRegistration registration,
}) {
  final DevelopmentSessionHistory session = DevelopmentSessionHistory(
    SessionId('session-$id'),
  )..append(UserSessionMessage(userContent));
  final AgentRun run = AgentRun(id: RunId('run-$id'), sessionId: session.id);
  final ToolCatalog catalog = ToolCatalog()..register(registration);
  return _RunFixture(
    session: session,
    run: run,
    strategy: DevelopmentToolLoopStrategy(
      run: run,
      session: session,
      contextAssembler: const DevelopmentContextAssembler(),
      model: model,
      toolCatalog: catalog,
      policy: const DevelopmentToolPolicy(ToolPolicyDecision.ask),
    ),
  );
}

ProviderDescriptor _modelDescriptor(String pluginId) => ProviderDescriptor(
  id: scriptedModelFixtureProviderId,
  capability: modelProviderCapability,
  pluginId: pluginId,
  displayName: 'Scripted Model Fixture',
  serviceId: modelProviderServiceId,
);

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
  final _CountingRequestChannel channel = _CountingRequestChannel(connection);
  final CapabilityRegistration registration = registry.register(
    provider: descriptor,
    endpoint: AdeleRequestChannelEndpoint(
      channel: channel,
      serviceId: descriptor.serviceId,
      isAvailable: () => !connection.isClosed,
    ),
  );
  return _ActiveProvider(
    connection: connection,
    activation: _TestCapabilityActivation(
      connection: connection,
      registration: registration,
    ),
    channel: channel,
  );
}

ToolRegistration _replaceExecutable(
  ToolRegistration registration,
  ToolExecutable executable,
) => ToolRegistration(
  definition: registration.definition,
  modelDefinition: registration.modelDefinition,
  executable: executable,
);

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

String _dartExecutable() {
  final String? flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final String executable =
        '$flutterRoot${Platform.pathSeparator}bin${Platform.pathSeparator}cache${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin${Platform.pathSeparator}${Platform.isWindows ? 'dart.exe' : 'dart'}';
    if (File(executable).existsSync()) return executable;
  }
  final String executable = Platform.resolvedExecutable;
  if (File(executable).parent.path.endsWith(
    '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin',
  )) {
    return executable;
  }
  throw StateError('Unable to locate the Dart SDK executable for AOT tests.');
}

final class _RunFixture {
  const _RunFixture({
    required this.session,
    required this.run,
    required this.strategy,
  });

  final DevelopmentSessionHistory session;
  final AgentRun run;
  final DevelopmentToolLoopStrategy strategy;
}

final class _ActiveProvider {
  const _ActiveProvider({
    required this.connection,
    required this.activation,
    required this.channel,
  });

  final PluginBackendConnection connection;
  final _TestCapabilityActivation activation;
  final _CountingRequestChannel channel;

  int get requestCount => channel.requestCount;
  int get streamCount => channel.streamCount;
}

final class _TestCapabilityActivation {
  const _TestCapabilityActivation({
    required this.connection,
    required this.registration,
  });

  final PluginBackendConnection connection;
  final CapabilityRegistration registration;

  Future<void> close() async {
    await registration.close();
    if (!connection.isClosed) await connection.close();
  }
}

final class _CountingRequestChannel implements AdeleStreamChannel {
  _CountingRequestChannel(this.delegate);

  final AdeleStreamChannel delegate;
  int requestCount = 0;
  int streamCount = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) {
    requestCount++;
    return delegate.request(method, payload);
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    streamCount++;
    return delegate.stream(method, payload);
  }
}

final class _AfterToolExecutable implements ToolExecutable {
  _AfterToolExecutable({required this.delegate, required this.afterTerminal});

  final ToolExecutable delegate;
  final Future<void> Function() afterTerminal;
  bool _ranCallback = false;

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) => delegate.describe(arguments, context);

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    await for (final ToolExecutionEvent event in delegate.execute(
      arguments,
      context,
    )) {
      if (event is ToolExecutionTerminal && !_ranCallback) {
        _ranCallback = true;
        await afterTerminal();
      }
      yield event;
    }
  }

  @override
  CanonicalToolArguments validateAndNormalize(
    Map<String, Object?> proposedArguments,
  ) => delegate.validateAndNormalize(proposedArguments);

  @override
  void validateBinding() => delegate.validateBinding();
}
