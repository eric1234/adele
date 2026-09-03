import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/development/agent/agent_capability_adapters.dart';
import 'package:adele_desktop/development/agent/development_agent_support.dart';
import 'package:adele_desktop/development/agent/simple_tool_loop_strategy.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:search_tools_plugin/search_tools_plugin.dart';

const String _gitEnvironmentPluginId = 'dev.adele.plugin.git-environment';
const String _gitEnvironmentProviderId = 'dev.adele.environment.git-worktree';

void main() {
  final bool enabled =
      Platform.environment['ADELE_OPENAI_CHATGPT_LIVE_TEST'] == '1';
  late String repository;
  late String dartaotruntime;
  late File hostArtifact;
  late File openAiArtifact;
  late File gitEnvironmentArtifact;

  setUpAll(() async {
    if (!enabled) return;
    repository = Directory.current.parent.path;
    final Directory artifacts = Directory(
      '$repository/.dart_tool/adele/integration/phase-iv-b-source-live',
    )..createSync(recursive: true);
    final String dart = _dartExecutable();
    dartaotruntime =
        '${File(dart).parent.path}/${Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime'}';
    hostArtifact = File('${artifacts.path}/host.aot');
    openAiArtifact = File('${artifacts.path}/openai.aot');
    gitEnvironmentArtifact = File('${artifacts.path}/git-environment.aot');
    await Future.wait(<Future<void>>[
      _compile(
        dart,
        '$repository/packages/plugin_backend_host/bin/adele_backend_host.dart',
        hostArtifact.path,
        repository,
      ),
      _compile(
        dart,
        '$repository/plugins/openai/packages/backend/bin/openai_model_provider_backend.dart',
        openAiArtifact.path,
        repository,
      ),
      _compile(
        dart,
        '$repository/plugins/git_environment/packages/backend/bin/'
        'git_environment_backend.dart',
        gitEnvironmentArtifact.path,
        repository,
      ),
    ]);
  });

  test(
    'experimental ChatGPT searches and reads the real ADELE strategy source',
    () async {
      const String strategyPath =
          'app/lib/development/agent/simple_tool_loop_strategy.dart';
      final Directory container = await Directory.systemTemp.createTemp(
        'adele-chatgpt-environment-source-',
      );
      addTearDown(() async {
        if (await container.exists()) await container.delete(recursive: true);
      });
      final Directory sourceRepository = Directory('${container.path}/source');
      await _createSourceRepository(
        repository: repository,
        source: sourceRepository,
      );
      final String credentialPath = _requiredEnvironment(
        'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE',
      );
      final Map<String, String> environment = <String, String>{
        'OPENAI_API_KEY': 'unused-live-source-coding-key',
        'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': credentialPath,
      };
      for (final String name in <String>[
        'ADELE_OPENAI_CHATGPT_CLIENT_ID',
        'ADELE_OPENAI_CHATGPT_INSTANCE_ID',
        'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER',
        'ADELE_OPENAI_CHATGPT_REDIRECT_URI',
        'ADELE_OPENAI_CHATGPT_ENDPOINT',
      ]) {
        final String? value = Platform.environment[name];
        if (value != null && value.trim().isNotEmpty) environment[name] = value;
      }
      if (!environment.containsKey('ADELE_OPENAI_CHATGPT_CLIENT_ID')) {
        environment['ADELE_OPENAI_CHATGPT_EXPERIMENTAL_CODEX_CLIENT'] = '1';
      }
      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
        environment: environment,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final CapabilityRegistry registry = CapabilityRegistry();
      final _Activation model = await _startProvider(
        host: host,
        registry: registry,
        pluginId: 'dev.adele.openai',
        artifact: openAiArtifact,
        descriptor: ProviderDescriptor(
          id: ProviderId('dev.adele.openai.chatgpt-experimental'),
          capability: modelProviderCapability,
          pluginId: 'dev.adele.openai',
          displayName: 'Experimental ChatGPT',
          serviceId: modelProviderServiceId,
        ),
        configurationContext: 'chatgpt-experimental',
      );
      addTearDown(model.close);
      final ProviderId environmentProviderId = ProviderId(
        _gitEnvironmentProviderId,
      );
      final PluginCapabilityActivation environmentActivation =
          await _startEnvironmentProvider(
            host: host,
            registry: registry,
            artifact: gitEnvironmentArtifact,
            providerId: environmentProviderId,
          );
      addTearDown(environmentActivation.close);
      final ModelProviderCapabilityAdapter modelAdapter =
          ModelProviderCapabilityAdapter(
            registry.resolve(
              modelProviderCapability,
              providerId: ProviderId('dev.adele.openai.chatgpt-experimental'),
            ),
            selectedModel:
                Platform.environment['ADELE_OPENAI_CHATGPT_TEST_MODEL'] ??
                'gpt-5.4',
          );
      final ProviderBinding environmentBinding = registry.resolve(
        environmentProviderCapability,
        providerId: environmentProviderId,
      );
      final InMemoryProductStore store = InMemoryProductStore();
      final ProductLifecycleCoordinator lifecycle =
          ProductLifecycleCoordinator.generated(
            store: store,
            registry: registry,
            ids: const _IntegrationIds(),
          );
      final Project project = lifecycle.createProject(sourceRepository.uri);
      final TaskCreationResult created = await lifecycle.createTask(
        projectId: project.id,
        title: 'Inspect ADELE source with ChatGPT',
        providerId: environmentProviderId,
      );
      final SessionId sessionId = SessionId('session-chatgpt-source-live');
      final SessionEnvironmentAuthority authority = store.associateSession(
        sessionId: sessionId,
        taskId: created.task.id,
      );
      expect(authority.environmentId, created.environment.id);
      final ProviderBinding materializedEnvironmentBinding = lifecycle
          .environmentRuntime
          .currentMaterialization(created.environment.id)!
          .binding;
      expect(
        materializedEnvironmentBinding.provider,
        same(environmentBinding.provider),
      );
      expect(
        materializedEnvironmentBinding.requestChannel,
        same(environmentBinding.requestChannel),
      );
      final ExtensionRegistry extensions = ExtensionRegistry();
      final ExtensionRegistration filesystemActivation =
          const FilesystemToolsPlugin().activate(extensions);
      addTearDown(filesystemActivation.close);
      final ExtensionRegistration searchActivation = const SearchToolsPlugin()
          .activate(extensions);
      addTearDown(searchActivation.close);
      final ToolCatalog catalog = await buildModelToolCatalogForSession(
        sessionId: sessionId,
        environmentRuntime: lifecycle.environmentRuntime,
        extensions: extensions,
      );
      final DevelopmentSessionHistory
      session = DevelopmentSessionHistory(sessionId)
        ..append(
          UserSessionMessage(
            'Locate the maintained ADELE file that declares DevelopmentToolLoopStrategy. Use search to locate it, then use read_file on the returned relative path. Report the exact relative path and the default maxModelInvocations value. You must inspect the source rather than answer from memory.',
          ),
        );
      final AgentRun run = AgentRun(
        id: RunId('run-chatgpt-source-live'),
        sessionId: session.id,
      );
      final DevelopmentToolLoopStrategy strategy = DevelopmentToolLoopStrategy(
        run: run,
        session: session,
        contextAssembler: const DevelopmentContextAssembler(
          instructions:
              'You must call search for "final class DevelopmentToolLoopStrategy", then call read_file with the relative path returned by search before answering.',
        ),
        model: modelAdapter,
        toolCatalog: catalog,
        policy: const DevelopmentToolPolicy(ToolPolicyDecision.allow),
      );

      await strategy.start();

      expect(run.state, RunState.completed);
      final List<ToolInvocationPrepared> prepared = run.journal.records
          .map((ExecutionEventRecord record) => record.event)
          .whereType<ToolInvocationPrepared>()
          .toList(growable: false);
      final Iterable<String> aliases = prepared.map(
        (event) => event.invocation.tool.modelDefinition.alias,
      );
      expect(aliases, containsAllInOrder(<String>['search', 'read_file']));
      expect(aliases.toSet(), <String>{'search', 'read_file'});
      expect(
        prepared.map((event) => event.invocation.tool.definition.id.value),
        contains('dev.adele.plugin.search-tools.search'),
      );
      expect(
        prepared.map((event) => event.invocation.tool.definition.id.value),
        contains('dev.adele.plugin.filesystem-tools.read-file'),
      );
      final List<ToolExecutionCompleted> completed = run.journal.records
          .map((ExecutionEventRecord record) => record.event)
          .whereType<ToolExecutionCompleted>()
          .toList(growable: false);
      expect(
        completed.map((event) => event.outcome.disposition),
        everyElement(ToolOutcomeDisposition.success),
      );
      expect(
        completed.map((event) => event.outcome.hostData['environmentId']),
        everyElement(authority.environmentId.value),
      );
      expect(
        completed.map((event) => event.outcome.hostData['matches']),
        contains(
          contains(
            isA<Map<String, Object?>>().having(
              (match) => match['relativePath'],
              'relativePath',
              strategyPath,
            ),
          ),
        ),
      );
      expect(
        completed.map((event) => event.outcome.hostData['relativePath']),
        contains(strategyPath),
      );
      final String answer =
          (session.snapshot().entries.last as AssistantSessionMessage).content;
      expect(answer.trim(), isNotEmpty);
      expect(answer, contains(strategyPath));
      expect(answer.toLowerCase(), anyOf(contains('8'), contains('eight')));

      await model.close();
      await searchActivation.close();
      await filesystemActivation.close();
      await environmentActivation.close();
      await host.close();
    },
    skip: enabled
        ? false
        : 'Set ADELE_OPENAI_CHATGPT_LIVE_TEST=1 and provide the existing local credential file to enable the experimental source-coding smoke.',
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

Future<PluginCapabilityActivation> _startEnvironmentProvider({
  required PluginBackendHost host,
  required CapabilityRegistry registry,
  required File artifact,
  required ProviderId providerId,
}) async {
  final PluginBackendConnection connection = await host.startPlugin(
    pluginId: _gitEnvironmentPluginId,
    artifactUri: artifact.uri,
  );
  return PluginCapabilityActivation.register(
    connection: connection,
    registry: registry,
    exposures: <PluginCapabilityExposure>[
      PluginCapabilityExposure(
        provider: ProviderDescriptor(
          id: providerId,
          capability: environmentProviderCapability,
          pluginId: connection.pluginId,
          displayName: 'Git Worktree Environment',
          serviceId: environmentProviderServiceId,
        ),
        configurationContext: connection.defaultConfigurationContext,
      ),
    ],
  );
}

Future<void> _createSourceRepository({
  required String repository,
  required Directory source,
}) async {
  const List<String> sourcePaths = <String>[
    'README.md',
    'app/lib/development/agent/development_agent_support.dart',
    'app/lib/development/agent/simple_tool_loop_strategy.dart',
  ];
  await source.create(recursive: true);
  for (final String relativePath in sourcePaths) {
    final File copied = File('${source.path}/$relativePath');
    await copied.parent.create(recursive: true);
    await File('$repository/$relativePath').copy(copied.path);
  }
  await _git(source, const <String>['init']);
  await _git(source, const <String>['config', 'user.name', 'ADELE Test']);
  await _git(source, const <String>[
    'config',
    'user.email',
    'adele@example.invalid',
  ]);
  await _git(source, const <String>['add', '.']);
  await _git(source, const <String>[
    'commit',
    '-m',
    'Add ADELE source fixture',
  ]);
}

Future<void> _git(Directory source, List<String> arguments) async {
  final ProcessResult result = await Process.run('git', <String>[
    '-C',
    source.path,
    ...arguments,
  ]);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
}

Future<_Activation> _startProvider({
  required PluginBackendHost host,
  required CapabilityRegistry registry,
  required String pluginId,
  required File artifact,
  required ProviderDescriptor descriptor,
  List<String> arguments = const <String>[],
  String? configurationContext,
}) async {
  final PluginBackendConnection connection = await host.startPlugin(
    pluginId: pluginId,
    artifactUri: artifact.uri,
    arguments: arguments,
  );
  final ConfigurationContextId context = configurationContext == null
      ? connection.defaultConfigurationContext
      : connection.configurationContext(configurationContext);
  final CapabilityRegistration registration = registry.register(
    provider: descriptor,
    endpoint: AdeleRequestChannelEndpoint(
      channel: connection.channelFor(context, descriptor.serviceId),
      serviceId: descriptor.serviceId,
      isAvailable: () => !connection.isClosed,
    ),
  );
  return _Activation(connection, registration);
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

String _requiredEnvironment(String name) {
  final String? value = Platform.environment[name];
  if (value == null || value.trim().isEmpty) {
    throw StateError('$name is required for the ChatGPT live test.');
  }
  return value;
}

final class _Activation {
  const _Activation(this.connection, this.registration);

  final PluginBackendConnection connection;
  final CapabilityRegistration registration;

  Future<void> close() async {
    await registration.close();
    if (!connection.isClosed) await connection.close();
  }
}

final class _IntegrationIds implements ProductIdSource {
  const _IntegrationIds();

  @override
  EnvironmentId nextEnvironmentId() =>
      EnvironmentId('environment-chatgpt-source-live');

  @override
  ProjectId nextProjectId() => ProjectId('project-chatgpt-source-live');

  @override
  TaskId nextTaskId() => TaskId('task-chatgpt-source-live');
}
