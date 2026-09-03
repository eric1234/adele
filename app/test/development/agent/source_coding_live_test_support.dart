import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/development/agent/agent_capability_adapters.dart';
import 'package:adele_desktop/development/agent/development_agent_support.dart';
import 'package:adele_desktop/development/agent/simple_tool_loop_strategy.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:search_tools_plugin/search_tools_plugin.dart';

const String sourceCodingStrategyPath =
    'app/lib/development/agent/simple_tool_loop_strategy.dart';
const String sourceCodingPrompt =
    'Locate the maintained ADELE file that declares '
    'DevelopmentToolLoopStrategy. Use search to locate it, then use '
    'read_file on the returned relative path. Report the exact relative '
    'path and the default maxModelInvocations value. You must inspect the '
    'source rather than answer from memory.';
const String sourceCodingInstructions =
    'You must call search for "final class DevelopmentToolLoopStrategy", '
    'then call read_file with the relative path returned by search before '
    'answering.';

const String _gitEnvironmentPluginId = 'dev.adele.plugin.git-environment';
const String _gitEnvironmentProviderId = 'dev.adele.environment.git-worktree';

final class SourceCodingLiveArtifacts {
  const SourceCodingLiveArtifacts({
    required this.repository,
    required this.dartAotRuntime,
    required this.hostArtifact,
    required this.openAiArtifact,
    required this.gitEnvironmentArtifact,
  });

  final String repository;
  final String dartAotRuntime;
  final File hostArtifact;
  final File openAiArtifact;
  final File gitEnvironmentArtifact;

  static Future<SourceCodingLiveArtifacts> compile(String scope) async {
    final String repository = Directory.current.parent.path;
    final Directory artifacts = Directory(
      '$repository/.dart_tool/adele/integration/$scope',
    )..createSync(recursive: true);
    final String dart = _dartExecutable();
    final SourceCodingLiveArtifacts result = SourceCodingLiveArtifacts(
      repository: repository,
      dartAotRuntime:
          '${File(dart).parent.path}/'
          '${Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime'}',
      hostArtifact: File('${artifacts.path}/host.aot'),
      openAiArtifact: File('${artifacts.path}/openai.aot'),
      gitEnvironmentArtifact: File('${artifacts.path}/git-environment.aot'),
    );
    await Future.wait(<Future<void>>[
      _compile(
        dart,
        '$repository/packages/plugin_backend_host/bin/'
        'adele_backend_host.dart',
        result.hostArtifact.path,
        repository,
      ),
      _compile(
        dart,
        '$repository/plugins/openai/packages/backend/bin/'
        'openai_model_provider_backend.dart',
        result.openAiArtifact.path,
        repository,
      ),
      _compile(
        dart,
        '$repository/plugins/git_environment/packages/backend/bin/'
        'git_environment_backend.dart',
        result.gitEnvironmentArtifact.path,
        repository,
      ),
    ]);
    return result;
  }
}

final class SourceCodingLiveHarness {
  SourceCodingLiveHarness._({
    required this.host,
    required this.registry,
    required this.sessionId,
    required this.authority,
    required this.catalog,
    required Directory container,
    required PluginCapabilityActivation environmentActivation,
    required ExtensionRegistration filesystemActivation,
    required ExtensionRegistration searchActivation,
  }) : _container = container,
       _environmentActivation = environmentActivation,
       _filesystemActivation = filesystemActivation,
       _searchActivation = searchActivation;

  final PluginBackendHost host;
  final CapabilityRegistry registry;
  final SessionId sessionId;
  final SessionEnvironmentAuthority authority;
  final ToolCatalog catalog;
  final Directory _container;
  final PluginCapabilityActivation _environmentActivation;
  final ExtensionRegistration _filesystemActivation;
  final ExtensionRegistration _searchActivation;

  bool _closed = false;

  static Future<SourceCodingLiveHarness> start({
    required SourceCodingLiveArtifacts artifacts,
    required Map<String, String> hostEnvironment,
    required String identity,
    required String taskTitle,
  }) async {
    final Directory container = await Directory.systemTemp.createTemp(
      'adele-$identity-environment-source-',
    );
    try {
      final Directory sourceRepository = Directory('${container.path}/source');
      await _createSourceRepository(
        repository: artifacts.repository,
        source: sourceRepository,
      );
      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: artifacts.dartAotRuntime,
        hostArtifactPath: artifacts.hostArtifact.path,
        environment: hostEnvironment,
      );
      final CapabilityRegistry registry = CapabilityRegistry();
      PluginCapabilityActivation? environmentActivation;
      ExtensionRegistration? filesystemActivation;
      ExtensionRegistration? searchActivation;
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
        filesystemActivation = const FilesystemToolsPlugin().activate(
          extensions,
        );
        searchActivation = const SearchToolsPlugin().activate(extensions);
        final ProviderBinding environmentBinding = registry.resolve(
          environmentProviderCapability,
          providerId: environmentProviderId,
        );
        final InMemoryProductStore store = InMemoryProductStore();
        final ProductLifecycleCoordinator lifecycle =
            ProductLifecycleCoordinator.generated(
              store: store,
              registry: registry,
              ids: _IntegrationIds(identity),
            );
        final Project project = lifecycle.createProject(sourceRepository.uri);
        final TaskCreationResult created = await lifecycle.createTask(
          projectId: project.id,
          title: taskTitle,
          providerId: environmentProviderId,
        );
        final SessionId sessionId = SessionId('session-$identity-source-live');
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
        final ToolCatalog catalog = await buildModelToolCatalogForSession(
          sessionId: sessionId,
          environmentRuntime: lifecycle.environmentRuntime,
          extensions: extensions,
        );
        return SourceCodingLiveHarness._(
          host: host,
          registry: registry,
          sessionId: sessionId,
          authority: authority,
          catalog: catalog,
          container: container,
          environmentActivation: environmentActivation,
          filesystemActivation: filesystemActivation,
          searchActivation: searchActivation,
        );
      } catch (error, stackTrace) {
        try {
          await _closeResources(<Future<void> Function()>[
            if (searchActivation != null) searchActivation.close,
            if (filesystemActivation != null) filesystemActivation.close,
            if (environmentActivation != null) environmentActivation.close,
            if (!host.isClosed) () => host.close(graceful: false),
          ]);
        } catch (_) {
          // Preserve the setup failure after attempting every cleanup.
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    } catch (_) {
      if (await container.exists()) await container.delete(recursive: true);
      rethrow;
    }
  }

  Future<SourceCodingLiveResult> run({
    required String identity,
    required ModelProviderCapabilityAdapter model,
  }) async {
    final DevelopmentSessionHistory session = DevelopmentSessionHistory(
      sessionId,
    )..append(UserSessionMessage(sourceCodingPrompt));
    final AgentRun run = AgentRun(
      id: RunId('run-$identity-source-live'),
      sessionId: session.id,
    );
    final DevelopmentToolLoopStrategy strategy = DevelopmentToolLoopStrategy(
      run: run,
      session: session,
      contextAssembler: const DevelopmentContextAssembler(
        instructions: sourceCodingInstructions,
      ),
      model: model,
      toolCatalog: catalog,
      policy: const DevelopmentToolPolicy(ToolPolicyDecision.allow),
    );

    await strategy.start();
    return SourceCodingLiveResult(run: run, session: session);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _closeResources(<Future<void> Function()>[
      _searchActivation.close,
      _filesystemActivation.close,
      _environmentActivation.close,
      if (!host.isClosed) host.close,
      if (await _container.exists()) () => _container.delete(recursive: true),
    ]);
  }
}

final class SourceCodingLiveResult {
  const SourceCodingLiveResult({required this.run, required this.session});

  final AgentRun run;
  final DevelopmentSessionHistory session;
}

void expectSuccessfulSourceCodingRun({
  required SourceCodingLiveResult result,
  required SessionEnvironmentAuthority authority,
}) {
  expect(result.run.state, RunState.completed);
  final List<ToolInvocationPrepared> prepared = result.run.journal.records
      .map((ExecutionEventRecord record) => record.event)
      .whereType<ToolInvocationPrepared>()
      .toList(growable: false);
  final Iterable<String> aliases = prepared.map(
    (event) => event.invocation.tool.modelDefinition.alias,
  );
  expect(aliases, containsAllInOrder(<String>['search', 'read_file']));
  expect(aliases.toSet(), <String>{'search', 'read_file'});
  expect(
    prepared
        .where(
          (event) => event.invocation.tool.modelDefinition.alias == 'search',
        )
        .map((event) => event.invocation.tool.definition.id.value),
    everyElement('dev.adele.plugin.search-tools.search'),
  );
  expect(
    prepared
        .where(
          (event) => event.invocation.tool.modelDefinition.alias == 'read_file',
        )
        .map((event) => event.invocation.tool.definition.id.value),
    everyElement('dev.adele.plugin.filesystem-tools.read-file'),
  );
  final List<ToolExecutionCompleted> completed = result.run.journal.records
      .map((ExecutionEventRecord record) => record.event)
      .whereType<ToolExecutionCompleted>()
      .toList(growable: false);
  expect(completed, hasLength(prepared.length));
  expect(
    completed.map((event) => event.outcome.disposition),
    everyElement(ToolOutcomeDisposition.success),
  );
  expect(
    completed.map((event) => event.outcome.hostData['environmentId']),
    everyElement(authority.environmentId.value),
  );

  final Map<ToolInvocationId, String> aliasesByInvocation =
      <ToolInvocationId, String>{
        for (final ToolInvocationPrepared event in prepared)
          event.invocation.id: event.invocation.tool.modelDefinition.alias,
      };
  final List<ExecutionEventRecord> records = result.run.journal.records;
  final Map<String, int> discoveredAt = <String, int>{};
  final Set<String> causallyReadPaths = <String>{};
  for (var index = 0; index < records.length; index++) {
    final ExecutionEvent event = records[index].event;
    if (event is ToolExecutionCompleted &&
        aliasesByInvocation[event.invocationId] == 'search') {
      final Object? matches = event.outcome.hostData['matches'];
      if (matches is List<Object?>) {
        for (final Map<String, Object?> match
            in matches.whereType<Map<String, Object?>>()) {
          if (match['relativePath'] case final String path) {
            discoveredAt.putIfAbsent(path, () => index);
          }
        }
      }
    }
    if (event is ToolInvocationPrepared &&
        event.invocation.tool.modelDefinition.alias == 'read_file') {
      final Object? path = event.invocation.canonicalArguments['relativePath'];
      if (path is String) {
        final int? discoveryIndex = discoveredAt[path];
        if (discoveryIndex != null && discoveryIndex < index) {
          causallyReadPaths.add(path);
        }
      }
    }
  }
  final Set<String> discoveredPaths = discoveredAt.keys.toSet();
  expect(discoveredPaths, contains(sourceCodingStrategyPath));
  expect(causallyReadPaths, contains(sourceCodingStrategyPath));
  expect(
    completed.map((event) => event.outcome.hostData['relativePath']),
    contains(sourceCodingStrategyPath),
  );

  final String answer =
      (result.session.snapshot().entries.last as AssistantSessionMessage)
          .content;
  expect(answer.trim(), isNotEmpty);
  expect(answer, contains(sourceCodingStrategyPath));
  expect(answer.toLowerCase(), anyOf(contains('8'), contains('eight')));
}

Future<void> _closeResources(List<Future<void> Function()> actions) async {
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
    sourceCodingStrategyPath,
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
  throw StateError('Unable to locate the Dart SDK executable for AOT tests.');
}

final class _IntegrationIds implements ProductIdSource {
  const _IntegrationIds(this.identity);

  final String identity;

  @override
  EnvironmentId nextEnvironmentId() =>
      EnvironmentId('environment-$identity-source-live');

  @override
  ProjectId nextProjectId() => ProjectId('project-$identity-source-live');

  @override
  TaskId nextTaskId() => TaskId('task-$identity-source-live');
}
