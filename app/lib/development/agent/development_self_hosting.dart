import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/development/agent/development_agent_support.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:search_tools_plugin/search_tools_plugin.dart';

const String developmentSelfHostingApiKeyProviderId =
    'dev.adele.openai.api-key';
const String developmentSelfHostingChatGptProviderId =
    'dev.adele.openai.chatgpt-experimental';
const String developmentSelfHostingChatGptDefaultModel = 'gpt-5.5';

const String _openAiPluginId = 'dev.adele.openai';
const String _chatGptConfigurationContext = 'chatgpt-experimental';
const String _gitEnvironmentPluginId = 'dev.adele.plugin.git-environment';
const String _gitEnvironmentProviderId = 'dev.adele.environment.git-worktree';

typedef DevelopmentSelfHostingLog = void Function(String message);

Map<String, String> developmentSelfHostingGitProcessEnvironment({
  Map<String, String>? inheritedEnvironment,
}) {
  final Map<String, String> environment = Map<String, String>.of(
    inheritedEnvironment ?? Platform.environment,
  );
  environment.removeWhere(
    (String name, String _) => name.toUpperCase().startsWith('GIT_'),
  );
  return environment;
}

enum DevelopmentSelfHostingProfile { chatgpt, apiKey }

extension DevelopmentSelfHostingProfileName on DevelopmentSelfHostingProfile {
  String get cliName => switch (this) {
    DevelopmentSelfHostingProfile.chatgpt => 'chatgpt',
    DevelopmentSelfHostingProfile.apiKey => 'api-key',
  };

  String get providerId => switch (this) {
    DevelopmentSelfHostingProfile.chatgpt =>
      developmentSelfHostingChatGptProviderId,
    DevelopmentSelfHostingProfile.apiKey =>
      developmentSelfHostingApiKeyProviderId,
  };

  String get configuredContext => switch (this) {
    DevelopmentSelfHostingProfile.chatgpt => _chatGptConfigurationContext,
    DevelopmentSelfHostingProfile.apiKey => 'default',
  };
}

final class DevelopmentSelfHostingProviderConfiguration {
  DevelopmentSelfHostingProviderConfiguration._({
    required this.profile,
    required this.selectedModel,
    required Map<String, String> hostEnvironment,
  }) : hostEnvironment = Map<String, String>.unmodifiable(hostEnvironment);

  final DevelopmentSelfHostingProfile profile;
  final String selectedModel;
  final Map<String, String> hostEnvironment;

  String get providerId => profile.providerId;
  String get configuredContext => profile.configuredContext;

  static DevelopmentSelfHostingProviderConfiguration fromEnvironment(
    DevelopmentSelfHostingProfile profile, {
    Map<String, String>? environment,
  }) {
    final Map<String, String> source = environment ?? Platform.environment;
    return switch (profile) {
      DevelopmentSelfHostingProfile.chatgpt =>
        DevelopmentSelfHostingProviderConfiguration._(
          profile: profile,
          selectedModel:
              _optionalEnvironment(source, 'ADELE_OPENAI_CHATGPT_TEST_MODEL') ??
              developmentSelfHostingChatGptDefaultModel,
          hostEnvironment: _chatGptHostEnvironment(source),
        ),
      DevelopmentSelfHostingProfile.apiKey =>
        DevelopmentSelfHostingProviderConfiguration._(
          profile: profile,
          selectedModel: _requiredEnvironment(
            source,
            'ADELE_OPENAI_TEST_MODEL',
          ),
          hostEnvironment: <String, String>{
            'OPENAI_API_KEY': _requiredEnvironment(source, 'OPENAI_API_KEY'),
            'ADELE_OPENAI_ENDPOINT':
                _optionalEnvironment(source, 'ADELE_OPENAI_ENDPOINT') ??
                'https://api.openai.com/v1/responses',
          },
        ),
    };
  }
}

final class DevelopmentSelfHostingArtifacts {
  const DevelopmentSelfHostingArtifacts({
    required this.repository,
    required this.dartAotRuntime,
    required this.directory,
    required this.hostArtifact,
    required this.openAiArtifact,
    required this.gitEnvironmentArtifact,
  });

  final Directory repository;
  final String dartAotRuntime;
  final Directory directory;
  final File hostArtifact;
  final File openAiArtifact;
  final File gitEnvironmentArtifact;

  static Future<DevelopmentSelfHostingArtifacts> compile({
    required Directory repository,
    required Directory outputDirectory,
    DevelopmentSelfHostingLog? log,
  }) async {
    await outputDirectory.create(recursive: true);
    final String dart = _dartExecutable();
    final DevelopmentSelfHostingArtifacts artifacts =
        DevelopmentSelfHostingArtifacts(
          repository: repository,
          dartAotRuntime:
              '${File(dart).parent.path}${Platform.pathSeparator}'
              '${Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime'}',
          directory: outputDirectory,
          hostArtifact: File('${outputDirectory.path}/host.aot'),
          openAiArtifact: File('${outputDirectory.path}/openai.aot'),
          gitEnvironmentArtifact: File(
            '${outputDirectory.path}/git-environment.aot',
          ),
        );
    await Future.wait(<Future<void>>[
      _compileAot(
        dart: dart,
        repository: repository,
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        output: artifacts.hostArtifact,
        log: log,
      ),
      _compileAot(
        dart: dart,
        repository: repository,
        entrypoint:
            'plugins/openai/packages/backend/bin/'
            'openai_model_provider_backend.dart',
        output: artifacts.openAiArtifact,
        log: log,
      ),
      _compileAot(
        dart: dart,
        repository: repository,
        entrypoint:
            'plugins/git_environment/packages/backend/bin/'
            'git_environment_backend.dart',
        output: artifacts.gitEnvironmentArtifact,
        log: log,
      ),
    ]);
    return artifacts;
  }
}

Future<void> cloneDevelopmentSelfHostingProject({
  required Directory repository,
  required Directory destination,
  required String sourceHead,
  DevelopmentSelfHostingLog? log,
  Map<String, String>? inheritedGitEnvironment,
}) async {
  log?.call('Cloning isolated Project source at ${destination.path}.');
  await _runChecked(
    'git',
    <String>[
      'clone',
      '--quiet',
      '--no-local',
      '--no-checkout',
      repository.path,
      destination.path,
    ],
    log: log,
    inheritedGitEnvironment: inheritedGitEnvironment,
  );
  await _runChecked(
    'git',
    <String>['checkout', '--quiet', '--detach', sourceHead],
    workingDirectory: destination.path,
    log: log,
    inheritedGitEnvironment: inheritedGitEnvironment,
  );
  // The model-visible clone must not retain a writable local origin pointing
  // back at the launching checkout.
  await _runChecked(
    'git',
    const <String>['remote', 'remove', 'origin'],
    workingDirectory: destination.path,
    log: log,
    inheritedGitEnvironment: inheritedGitEnvironment,
  );
  final String clonedHead = (await _runChecked(
    'git',
    const <String>['rev-parse', 'HEAD'],
    workingDirectory: destination.path,
    log: log,
    inheritedGitEnvironment: inheritedGitEnvironment,
  )).stdout.toString().trim();
  if (clonedHead != sourceHead) {
    throw StateError(
      'The isolated Project clone resolved $clonedHead instead of $sourceHead.',
    );
  }
}

final class DevelopmentSelfHostingTopology {
  DevelopmentSelfHostingTopology._({
    required this.host,
    required this.registry,
    required this.store,
    required this.lifecycle,
    required this.chat,
    required this.project,
    required this.task,
    required this.environment,
    required this.session,
    required this.authority,
    required this.catalog,
    required this.projectSource,
    required PluginCapabilityActivation environmentActivation,
    required ExtensionRegistration strategyActivation,
    required ExtensionRegistration filesystemActivation,
    required ExtensionRegistration searchActivation,
    required ExtensionRegistration? commandActivation,
  }) : _environmentActivation = environmentActivation,
       _strategyActivation = strategyActivation,
       _filesystemActivation = filesystemActivation,
       _searchActivation = searchActivation,
       _commandActivation = commandActivation;

  final PluginBackendHost host;
  final CapabilityRegistry registry;
  final InMemoryProductStore store;
  final ProductLifecycleCoordinator lifecycle;
  final ChatStrategyPlugin chat;
  final Project project;
  final Task task;
  final Environment environment;
  final Session session;
  final SessionEnvironmentAuthority authority;
  final ToolCatalog catalog;
  final Directory projectSource;
  final PluginCapabilityActivation _environmentActivation;
  final ExtensionRegistration _strategyActivation;
  final ExtensionRegistration _filesystemActivation;
  final ExtensionRegistration _searchActivation;
  final ExtensionRegistration? _commandActivation;
  bool _closed = false;

  SessionId get sessionId => session.id;

  static Future<DevelopmentSelfHostingTopology> start({
    required DevelopmentSelfHostingArtifacts artifacts,
    required Directory projectSource,
    required Map<String, String> hostEnvironment,
    required String identity,
    required String taskTitle,
    bool includeCommandTools = true,
    DevelopmentSelfHostingLog? log,
    void Function(DevelopmentSelfHostingRetainedState state)? onTaskEstablished,
  }) async {
    final PluginBackendHost host = await PluginBackendHost.start(
      dartaotruntimeExecutable: artifacts.dartAotRuntime,
      hostArtifactPath: artifacts.hostArtifact.path,
      environment: hostEnvironment,
    );
    final CapabilityRegistry registry = CapabilityRegistry();
    PluginCapabilityActivation? environmentActivation;
    ExtensionRegistration? strategyActivation;
    ExtensionRegistration? filesystemActivation;
    ExtensionRegistration? searchActivation;
    ExtensionRegistration? commandActivation;
    try {
      final ProviderId environmentProviderId = ProviderId(
        _gitEnvironmentProviderId,
      );
      environmentActivation = await _startEnvironmentProvider(
        host: host,
        registry: registry,
        artifact: artifacts.gitEnvironmentArtifact,
        providerId: environmentProviderId,
      );
      final ExtensionRegistry extensions = ExtensionRegistry();
      final ChatStrategyPlugin chat = ChatStrategyPlugin();
      strategyActivation = chat.activate(extensions);
      filesystemActivation = const FilesystemToolsPlugin().activate(extensions);
      searchActivation = const SearchToolsPlugin().activate(extensions);
      if (includeCommandTools) {
        commandActivation = const CommandToolsPlugin().activate(extensions);
      }
      final ProviderBinding environmentBinding = registry.resolve(
        environmentProviderCapability,
        providerId: environmentProviderId,
      );
      final InMemoryProductStore store = InMemoryProductStore();
      final ProductLifecycleCoordinator lifecycle =
          ProductLifecycleCoordinator.generated(
            store: store,
            registry: registry,
            extensions: extensions,
            ids: _DevelopmentSelfHostingIds(identity),
          );
      final Project project = lifecycle.createProject(projectSource.uri);
      final TaskCreationResult created = await lifecycle.createTask(
        projectId: project.id,
        title: taskTitle,
        providerId: environmentProviderId,
      );
      final DevelopmentSelfHostingRetainedState retainedState =
          DevelopmentSelfHostingRetainedState(
            projectSource: projectSource,
            projectId: project.id,
            taskId: created.task.id,
            environmentId: created.environment.id,
            taskWorktreePath: _providerStateString(
              created.environment,
              'worktreePath',
            ),
            taskBranch: _providerStateString(created.environment, 'branch'),
            baselineCommit: _providerStateString(
              created.environment,
              'baselineCommit',
            ),
          );
      onTaskEstablished?.call(retainedState);
      final Session session = lifecycle.createSession(
        taskId: created.task.id,
        strategyId: chatStrategyId,
      );
      final SessionEnvironmentAuthority authority = store
          .requireSessionAuthority(session.id);
      if (authority.environmentId != created.environment.id) {
        throw StateError('Session authority selected another Environment.');
      }
      final EnvironmentMaterialization environmentMaterialization = lifecycle
          .environmentRuntime
          .currentMaterialization(created.environment.id)!;
      if (!identical(
            environmentMaterialization.binding.provider,
            environmentBinding.provider,
          ) ||
          !identical(
            environmentMaterialization.binding.requestChannel,
            environmentBinding.requestChannel,
          )) {
        throw StateError(
          'Task establishment changed the selected Environment binding.',
        );
      }
      final ToolCatalog catalog = await buildModelToolCatalogForSession(
        sessionId: session.id,
        environmentRuntime: lifecycle.environmentRuntime,
        extensions: extensions,
      );
      final DevelopmentSelfHostingTopology topology =
          DevelopmentSelfHostingTopology._(
            host: host,
            registry: registry,
            store: store,
            lifecycle: lifecycle,
            chat: chat,
            project: project,
            task: created.task,
            environment: created.environment,
            session: session,
            authority: authority,
            catalog: catalog,
            projectSource: projectSource,
            environmentActivation: environmentActivation,
            strategyActivation: strategyActivation,
            filesystemActivation: filesystemActivation,
            searchActivation: searchActivation,
            commandActivation: commandActivation,
          );
      log?.call('Project source: ${topology.projectSource.path}');
      log?.call('Task worktree: ${topology.taskWorktreePath}');
      return topology;
    } catch (error, stackTrace) {
      try {
        await closeDevelopmentSelfHostingResources(<Future<void> Function()>[
          if (commandActivation != null) commandActivation.close,
          if (searchActivation != null) searchActivation.close,
          if (filesystemActivation != null) filesystemActivation.close,
          if (strategyActivation != null) strategyActivation.close,
          if (environmentActivation != null) environmentActivation.close,
          if (!host.isClosed) () => host.close(graceful: false),
        ]);
      } on Object {
        // Preserve the setup failure after attempting every cleanup action.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  EnvironmentMaterialization get environmentMaterialization {
    final EnvironmentMaterialization? materialization = lifecycle
        .environmentRuntime
        .currentMaterialization(environment.id);
    if (materialization == null) {
      throw StateError('The Task Environment is not materialized.');
    }
    return materialization;
  }

  String get taskWorktreePath => _requiredProviderStateString('worktreePath');

  String get taskBranch => _requiredProviderStateString('branch');

  String get baselineCommit => _requiredProviderStateString('baselineCommit');

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await closeDevelopmentSelfHostingResources(<Future<void> Function()>[
      if (_commandActivation != null) _commandActivation.close,
      _searchActivation.close,
      _filesystemActivation.close,
      _strategyActivation.close,
      _environmentActivation.close,
      if (!host.isClosed) host.close,
    ]);
  }

  String _requiredProviderStateString(String name) {
    final Object? value = environment.providerState?[name];
    if (value is! String || value.isEmpty) {
      throw StateError('The Git Environment has no $name value.');
    }
    return value;
  }
}

final class DevelopmentSelfHostingRetainedState {
  const DevelopmentSelfHostingRetainedState({
    required this.projectSource,
    required this.projectId,
    required this.taskId,
    required this.environmentId,
    required this.taskWorktreePath,
    required this.taskBranch,
    required this.baselineCommit,
  });

  final Directory projectSource;
  final ProjectId projectId;
  final TaskId taskId;
  final EnvironmentId environmentId;
  final String taskWorktreePath;
  final String taskBranch;
  final String baselineCommit;
}

final class DevelopmentSelfHostingProviderActivation {
  const DevelopmentSelfHostingProviderActivation(this._activation);

  final PluginCapabilityActivation _activation;

  Future<void> close() => _activation.close();
}

Future<DevelopmentSelfHostingProviderActivation>
activateDevelopmentSelfHostingModelProvider({
  required PluginBackendHost host,
  required CapabilityRegistry registry,
  required File artifact,
  required DevelopmentSelfHostingProfile profile,
}) async {
  final PluginBackendConnection connection = await host.startPlugin(
    pluginId: _openAiPluginId,
    artifactUri: artifact.uri,
  );
  try {
    final ProviderDescriptor descriptor = ProviderDescriptor(
      id: ProviderId(profile.providerId),
      capability: modelProviderCapability,
      pluginId: _openAiPluginId,
      displayName: switch (profile) {
        DevelopmentSelfHostingProfile.chatgpt => 'Experimental ChatGPT',
        DevelopmentSelfHostingProfile.apiKey => 'OpenAI API Key',
      },
      serviceId: modelProviderServiceId,
    );
    final PluginCapabilityActivation activation =
        await PluginCapabilityActivation.register(
          connection: connection,
          registry: registry,
          exposures: <PluginCapabilityExposure>[
            PluginCapabilityExposure(
              provider: descriptor,
              configurationContext: switch (profile) {
                DevelopmentSelfHostingProfile.chatgpt =>
                  connection.configurationContext(_chatGptConfigurationContext),
                DevelopmentSelfHostingProfile.apiKey =>
                  connection.defaultConfigurationContext,
              },
            ),
          ],
        );
    return DevelopmentSelfHostingProviderActivation(activation);
  } catch (_) {
    if (!connection.isClosed) await connection.close();
    rethrow;
  }
}

final class DevelopmentSelfHostingRunResult {
  const DevelopmentSelfHostingRunResult({
    required this.run,
    required this.session,
    required this.finalAssistantResponse,
    required this.executionFailure,
    required this.executionStackTrace,
  });

  final AgentRun run;
  final ChatSessionState session;

  /// Captured for this Run, independent of later changes to the retained Session.
  final String? finalAssistantResponse;
  final Object? executionFailure;
  final StackTrace? executionStackTrace;

  bool get succeeded => run.state == RunState.completed;
  int get exitCode => succeeded ? 0 : 1;
}

Future<DevelopmentSelfHostingRunResult> executeDevelopmentSelfHostingRun({
  required String identity,
  required ProductLifecycleCoordinator lifecycle,
  required ChatSessionStore sessions,
  required SessionId sessionId,
  required String prompt,
  required String instructions,
  required ModelPort model,
  required ToolCatalog catalog,
  required int maxModelInvocations,
}) async {
  final ChatSessionState session = sessions.obtain(sessionId)
    ..instructions = instructions
    ..maxModelInvocations = maxModelInvocations
    ..append(ChatUserMessage(prompt));
  final int initialEntryCount = session.snapshot().entries.length;
  final SessionOrchestrationRun execution = createSessionOrchestrationRun(
    lifecycle: lifecycle,
    sessionId: sessionId,
    runId: RunId('run-$identity'),
    model: model,
    toolCatalog: catalog,
    policy: const DevelopmentToolPolicy(ToolPolicyDecision.allow),
  );
  Object? executionFailure;
  StackTrace? executionStackTrace;
  try {
    await execution.start();
  } on Object catch (error, stackTrace) {
    executionFailure = error;
    executionStackTrace = stackTrace;
  }
  final List<ChatEntry> entries = session.snapshot().entries;
  final ChatEntry? finalEntry =
      execution.run.state == RunState.completed &&
          entries.length > initialEntryCount
      ? entries.last
      : null;
  return DevelopmentSelfHostingRunResult(
    run: execution.run,
    session: session,
    finalAssistantResponse: finalEntry is ChatAssistantMessage
        ? finalEntry.content
        : null,
    executionFailure: executionFailure,
    executionStackTrace: executionStackTrace,
  );
}

Future<void> closeDevelopmentSelfHostingResources(
  List<Future<void> Function()> actions,
) async {
  Object? firstError;
  StackTrace? firstStackTrace;
  for (final Future<void> Function() action in actions) {
    try {
      await action();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
}

Map<String, String> _chatGptHostEnvironment(Map<String, String> source) {
  final Map<String, String> environment = <String, String>{
    // The backend currently also establishes its default API-key context.
    'OPENAI_API_KEY': 'unused-development-self-hosting-key',
    'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': _requiredEnvironment(
      source,
      'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE',
    ),
  };
  for (final String name in <String>[
    'ADELE_OPENAI_CHATGPT_CLIENT_ID',
    'ADELE_OPENAI_CHATGPT_INSTANCE_ID',
    'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER',
    'ADELE_OPENAI_CHATGPT_REDIRECT_URI',
    'ADELE_OPENAI_CHATGPT_ENDPOINT',
  ]) {
    final String? value = _optionalEnvironment(source, name);
    if (value != null) environment[name] = value;
  }
  if (!environment.containsKey('ADELE_OPENAI_CHATGPT_CLIENT_ID')) {
    environment['ADELE_OPENAI_CHATGPT_EXPERIMENTAL_CODEX_CLIENT'] = '1';
  }
  return environment;
}

String _requiredEnvironment(Map<String, String> environment, String name) {
  final String? value = _optionalEnvironment(environment, name);
  if (value == null) {
    throw StateError('$name is required for developer self-hosting.');
  }
  return value;
}

String? _optionalEnvironment(Map<String, String> environment, String name) {
  final String? value = environment[name];
  return value == null || value.trim().isEmpty ? null : value;
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

Future<void> _compileAot({
  required String dart,
  required Directory repository,
  required String entrypoint,
  required File output,
  DevelopmentSelfHostingLog? log,
}) async {
  log?.call('Compiling $entrypoint.');
  await _runChecked(
    dart,
    <String>['compile', 'aot-snapshot', entrypoint, '-o', output.path],
    workingDirectory: repository.path,
    log: log,
  );
}

Future<ProcessResult> _runChecked(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  DevelopmentSelfHostingLog? log,
  Map<String, String>? inheritedGitEnvironment,
}) async {
  final bool isGit = executable == 'git';
  final ProcessResult result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    runInShell: Platform.isWindows,
    environment: isGit
        ? developmentSelfHostingGitProcessEnvironment(
            inheritedEnvironment: inheritedGitEnvironment,
          )
        : null,
    includeParentEnvironment: !isGit,
  );
  final String stdoutText = result.stdout.toString().trim();
  final String stderrText = result.stderr.toString().trim();
  if (stdoutText.isNotEmpty) log?.call(stdoutText);
  if (stderrText.isNotEmpty) log?.call(stderrText);
  if (result.exitCode != 0) {
    throw StateError(
      '$executable ${arguments.join(' ')} exited ${result.exitCode}: '
      '${stderrText.isEmpty ? stdoutText : stderrText}',
    );
  }
  return result;
}

String _dartExecutable() {
  final String? flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final String executable =
        '$flutterRoot${Platform.pathSeparator}bin${Platform.pathSeparator}'
        'cache${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}${Platform.isWindows ? 'dart.exe' : 'dart'}';
    if (File(executable).existsSync()) return executable;
  }
  final String executable = Platform.resolvedExecutable;
  if (File(executable).parent.path.endsWith(
    '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin',
  )) {
    return executable;
  }
  throw StateError('Unable to locate the Dart SDK executable.');
}

final class _DevelopmentSelfHostingIds implements ProductIdSource {
  const _DevelopmentSelfHostingIds(this.identity);

  final String identity;

  @override
  EnvironmentId nextEnvironmentId() => EnvironmentId('environment-$identity');

  @override
  ProjectId nextProjectId() => ProjectId('project-$identity');

  @override
  SessionId nextSessionId() => SessionId('session-$identity');

  @override
  TaskId nextTaskId() => TaskId('task-$identity');
}

String _providerStateString(Environment environment, String name) {
  final Object? value = environment.providerState?[name];
  if (value is! String || value.isEmpty) {
    throw StateError('The Git Environment has no $name value.');
  }
  return value;
}
