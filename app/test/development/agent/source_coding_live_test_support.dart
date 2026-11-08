import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_desktop/core/prepared_settings.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/resource_cleanup.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_contract/chat_strategy_contract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../../../tools/backend_artifacts.dart';
import '../../support/fixed_tool_policy.dart';
import '../../support/git_worktree_fixture.dart';

const String sourceCodingStrategyPath =
    'plugins/chat_strategy/settings.schema.json';
const String sourceCodingPrompt =
    'Locate the maintained ADELE file that declares '
    'the dev.adele.plugin.chat-strategy.max-model-invocations setting. '
    'Use search to locate it, then use '
    'read_file on the returned relative path. Report the exact relative '
    'path and the declared default value. You must inspect the '
    'source rather than answer from memory.';
const String sourceCodingInstructions =
    'You must call search for "dev.adele.plugin.chat-strategy.max-model-invocations", '
    'then call read_file with the relative path returned by search before '
    'answering.';
const String openAiApiKeyProviderId = 'dev.adele.openai.api-key';
const String openAiChatGptProviderId = 'dev.adele.openai.chatgpt-experimental';
const String sourceCodingChatGptDefaultModel = 'gpt-6-astra';

final class SourceCodingLiveArtifacts {
  const SourceCodingLiveArtifacts({
    required this.repository,
    required this.dartAotRuntime,
    required this.hostArtifact,
    required this.openAiArtifact,
    required this.backends,
  });

  final String repository;
  final String dartAotRuntime;
  final File hostArtifact;
  final File openAiArtifact;
  final Map<String, File> backends;

  static Future<SourceCodingLiveArtifacts> compile(String scope) async {
    final Directory repository = Directory.current.parent;
    final Directory output = Directory(
      '${repository.path}/.dart_tool/adele/integration/$scope',
    );
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    final sdkBin = flutterRoot == null
        ? File(Platform.resolvedExecutable).parent
        : Directory.fromUri(
            Directory(flutterRoot).uri.resolve('bin/cache/dart-sdk/bin/'),
          );
    if (!sdkBin.path.endsWith(
      '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin',
    )) {
      throw StateError('Set FLUTTER_ROOT to the pinned Flutter SDK.');
    }
    final dart = File.fromUri(
      sdkBin.uri.resolve(Platform.isWindows ? 'dart.exe' : 'dart'),
    ).path;
    const entrypoints = {
      'host': 'packages/plugin_backend_host/bin/adele_backend_host.dart',
      'openai':
          'plugins/openai/packages/backend/bin/openai_model_provider_backend.dart',
      'dev.adele.plugin.chat-strategy':
          'plugins/chat_strategy/packages/backend/bin/chat_strategy_backend.dart',
      'dev.adele.plugin.git':
          'plugins/git/packages/backend/bin/git_backend.dart',
      'dev.adele.plugin.agents-md':
          'plugins/agents_md/packages/backend/bin/agents_md_backend.dart',
      'dev.adele.plugin.command-tools':
          'plugins/command_tools/packages/backend/bin/command_tools_backend.dart',
      'dev.adele.plugin.search-tools':
          'plugins/search_tools/packages/backend/bin/search_tools_backend.dart',
      'dev.adele.plugin.filesystem-tools':
          'plugins/filesystem_tools/packages/backend/bin/filesystem_tools_backend.dart',
    };
    final artifacts = <String, File>{};
    for (final entry in entrypoints.entries) {
      final artifact = File('${output.path}/${entry.key}.aot');
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repository,
        entrypoint: entry.value,
        artifact: artifact,
        stage: 'source-coding-test',
      );
      artifacts[entry.key] = artifact;
    }
    return SourceCodingLiveArtifacts(
      repository: repository.path,
      dartAotRuntime: File.fromUri(
        sdkBin.uri.resolve(
          Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
        ),
      ).path,
      hostArtifact: artifacts.remove('host')!,
      openAiArtifact: artifacts.remove('openai')!,
      backends: artifacts,
    );
  }
}

/// Source-coding fixture over normal prepared-plugin startup, shared by the
/// deterministic Environment test and explicitly gated live-provider tests.
final class SourceCodingLiveHarness {
  SourceCodingLiveHarness._(
    this.runtime,
    this._container,
    this.projectSource,
    this._artifacts,
    this._hostEnvironment,
  );

  final AdeleRuntime runtime;
  final Directory _container;
  final Directory projectSource;
  final SourceCodingLiveArtifacts _artifacts;
  final Map<String, String> _hostEnvironment;
  late final Project project;
  late final Task task;
  late final Environment environment;
  late final Session session;
  late final ToolCatalog catalog;
  late final ChatSessionServiceClient chatSession;
  bool _closed = false;

  PluginBackendHost get host => runtime.plugins.host!;
  CapabilityRegistry get registry => runtime.registry;
  InMemoryProductStore get store => runtime.store;
  ProductLifecycleCoordinator get lifecycle => runtime.lifecycle;
  InferenceContextComposer get contextComposer => runtime.contextComposer;
  SessionId get sessionId => session.id;
  SessionEnvironmentAuthority get authority =>
      store.requireSessionAuthority(sessionId);
  ResolvedOrchestrationStrategy get resolvedStrategy =>
      lifecycle.resolveSessionStrategy(sessionId);
  EnvironmentMaterialization get environmentMaterialization =>
      lifecycle.environmentRuntime.currentMaterialization(environment.id)!;

  static Future<SourceCodingLiveHarness> start({
    required SourceCodingLiveArtifacts artifacts,
    required Map<String, String> hostEnvironment,
    required String identity,
    required String taskTitle,
    bool enableCommandTools = false,
    int maxModelInvocations = 8,
  }) async {
    final Directory container = await Directory.systemTemp.createTemp(
      'adele-$identity-environment-source-',
    );
    final runtime = AdeleRuntime(ids: MonotonicProductIdSource(seed: identity));
    try {
      final Directory sourceRepository = Directory('${container.path}/source');
      await _createSourceRepository(
        repository: artifacts.repository,
        source: sourceRepository,
      );
      final installations = Directory('${container.path}/installations');
      var index = 0;
      for (final entry in artifacts.backends.entries) {
        if (!enableCommandTools &&
            entry.key == 'dev.adele.plugin.command-tools') {
          continue;
        }
        final installation = Directory(
          '${installations.path}/${index++}-${entry.key}',
        );
        await publishStockPluginInstallation(
          repositoryRoot: Directory(artifacts.repository),
          installationDirectory: installation,
          pluginId: entry.key,
          displayName: entry.key,
          backend: true,
        );
        await entry.value.copy('${installation.path}/backend.aot');
      }
      runtime.plugins.configureSettingsLoader(
        (catalog) async => PreparedSettingsSnapshot.resolve(
          catalog,
          globalOverrides: {
            SettingId(chatMaxModelInvocationsSettingId): maxModelInvocations,
          },
        ),
      );
      await runtime.plugins.start(
        installationRoot: installations.path,
        dartaotruntimeExecutable: artifacts.dartAotRuntime,
        hostArtifactPath: artifacts.hostArtifact.path,
        startupArguments: const {},
      );
      expect(runtime.plugins.failure, isNull);
      for (final backend in runtime.plugins.backends) {
        expect(
          backend.state,
          InstalledBackendState.active,
          reason: '${backend.failure}',
        );
      }
      final fixture = SourceCodingLiveHarness._(
        runtime,
        container,
        sourceRepository,
        artifacts,
        Map.unmodifiable(hostEnvironment),
      );
      fixture.project = runtime.lifecycle.createProject(sourceRepository.uri);
      final created = await runtime.lifecycle.createTask(
        projectId: fixture.project.id,
        title: taskTitle,
        providerId: ProviderId('dev.adele.environment.git-worktree'),
      );
      fixture.task = created.task;
      fixture.environment = created.environment;
      fixture.session = runtime.lifecycle.createSession(
        taskId: created.task.id,
        strategyId: chatStrategyId,
      );
      final chat = runtime.plugins.backends.singleWhere(
        (backend) => backend.installation.metadata.id == chatStrategyPluginId,
      );
      final connection = chat.connection!;
      expect(
        chat.strategyOrigin(fixture.resolvedStrategy.binding)!.connection,
        same(connection),
      );
      fixture.chatSession = ChatSessionServiceClient(
        connection.channelFor(
          connection.defaultConfigurationContext,
          chatSessionServiceId,
        ),
      );
      fixture.catalog = await buildModelToolCatalogForSession(
        sessionId: fixture.sessionId,
        environmentRuntime: runtime.lifecycle.environmentRuntime,
        extensions: runtime.extensions,
      );
      return fixture;
    } catch (error, stackTrace) {
      try {
        await closeResources([
          runtime.close,
          () => container.delete(recursive: true),
        ]);
      } on Object {
        // Preserve setup failure after attempting both cleanup actions.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<SourceCodingLiveResult> run({
    required String identity,
    required ModelPort model,
    String userPrompt = sourceCodingPrompt,
    String developmentInstructions = sourceCodingInstructions,
  }) async {
    await chatSession.configureSession(
      sessionId.value,
      developmentInstructions,
    );
    await chatSession.appendUserMessage(sessionId.value, userPrompt);
    final execution = await createSessionOrchestrationRun(
      lifecycle: lifecycle,
      resolvedStrategy: resolvedStrategy,
      contextComposer: contextComposer,
      sessionId: sessionId,
      runId: RunId('run-$identity-source-live'),
      model: model,
      toolCatalog: catalog,
      policy: const FixedToolPolicy(ToolPolicyDecision.allow),
    );
    try {
      await execution.start();
    } finally {
      await execution.close();
    }
    return SourceCodingLiveResult(
      run: execution.run,
      session: await chatSession.snapshot(sessionId.value),
    );
  }

  String get projectSourcePath => projectSource.path;

  String get taskWorktreePath => gitWorktreeFixturePath(project, environment);

  Future<String> readProjectSourceFile(String relativePath) =>
      File('${projectSource.path}/$relativePath').readAsString();

  Future<String> readTaskWorktreeFile(String relativePath) =>
      File('$taskWorktreePath/$relativePath').readAsString();

  Future<EnvironmentTextFile> readEnvironmentFile(String relativePath) =>
      environmentMaterialization.provider.readFile(
        authority.environmentId,
        relativePath,
      );

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await closeResources(<Future<void> Function()>[
      runtime.close,
      if (await _container.exists()) () => _container.delete(recursive: true),
    ]);
  }
}

Future<SourceCodingLiveProviderActivation> startOpenAiApiKeyProvider({
  required SourceCodingLiveHarness harness,
}) => _startOpenAiProvider(harness, openAiApiKeyProviderId);

Map<String, String> sourceCodingChatGptHostEnvironment() {
  final source = Platform.environment;
  final credentialFile = source['ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE'];
  if (credentialFile == null || credentialFile.trim().isEmpty) {
    throw StateError(
      'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE is required for the live test.',
    );
  }
  final environment = <String, String>{
    'OPENAI_API_KEY': '',
    'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': credentialFile,
  };
  for (final name in [
    'ADELE_OPENAI_CHATGPT_CLIENT_ID',
    'ADELE_OPENAI_CHATGPT_INSTANCE_ID',
    'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER',
    'ADELE_OPENAI_CHATGPT_REDIRECT_URI',
    'ADELE_OPENAI_CHATGPT_ENDPOINT',
  ]) {
    final value = source[name];
    if (value != null && value.trim().isNotEmpty) environment[name] = value;
  }
  if (!environment.containsKey('ADELE_OPENAI_CHATGPT_CLIENT_ID')) {
    environment['ADELE_OPENAI_CHATGPT_EXPERIMENTAL_CODEX_CLIENT'] = '1';
  }
  return environment;
}

String sourceCodingChatGptSelectedModel() {
  final selected = Platform.environment['ADELE_OPENAI_CHATGPT_TEST_MODEL'];
  return selected == null || selected.trim().isEmpty
      ? sourceCodingChatGptDefaultModel
      : selected;
}

Future<SourceCodingLiveProviderActivation> startOpenAiChatGptProvider({
  required SourceCodingLiveHarness harness,
}) => _startOpenAiProvider(harness, openAiChatGptProviderId);

Future<SourceCodingLiveProviderActivation> _startOpenAiProvider(
  SourceCodingLiveHarness harness,
  String providerId,
) async {
  // Apply explicit provider configuration only when an opted-in test starts it.
  // Normal source/runtime bootstrap stays provider-free.
  final host = await PluginBackendHost.start(
    dartaotruntimeExecutable: harness._artifacts.dartAotRuntime,
    hostArtifactPath: harness._artifacts.hostArtifact.path,
    environment: harness._hostEnvironment,
  );
  try {
    final activation = await PluginCapabilityActivation.registerAdvertised(
      connection: await host.startPlugin(
        pluginId: 'dev.adele.openai',
        artifactUri: harness._artifacts.openAiArtifact.uri,
      ),
      registry: harness.registry,
    );
    final result = SourceCodingLiveProviderActivation(host, activation);
    try {
      harness.registry.resolve(
        modelProviderCapability,
        providerId: ProviderId(providerId),
      );
      return result;
    } on Object {
      await result.close();
      rethrow;
    }
  } on Object {
    if (!host.isClosed) await host.close();
    rethrow;
  }
}

final class SourceCodingLiveProviderActivation {
  const SourceCodingLiveProviderActivation(this._host, this._activation);

  final PluginBackendHost _host;
  final PluginCapabilityActivation _activation;

  Future<void> close() =>
      closeResources([_activation.close, if (!_host.isClosed) _host.close]);
}

final class SourceCodingLiveResult {
  const SourceCodingLiveResult({required this.run, required this.session});

  final AgentRun run;
  final ChatSessionSnapshot session;
}

/// A prepared tool invocation and its unique terminal outcome in a Run journal.
final class SourceCodingToolAttempt {
  const SourceCodingToolAttempt({
    required this.preparedRecord,
    required this.terminalRecord,
  });

  final ExecutionEventRecord preparedRecord;
  final ExecutionEventRecord terminalRecord;

  ToolInvocationPrepared get prepared =>
      preparedRecord.event as ToolInvocationPrepared;

  ToolOutcome get outcome => switch (terminalRecord.event) {
    ToolExecutionCompleted(:final outcome) ||
    ToolInvocationCompleted(:final outcome) => outcome,
    _ => throw StateError('The tool attempt has no terminal outcome.'),
  };
}

/// Correlates each prepared invocation of [alias] with its terminal event.
///
/// A missing or duplicate terminal event is rejected so live tests cannot
/// accidentally assert against incomplete or ambiguous Run evidence.
List<SourceCodingToolAttempt> sourceCodingToolAttempts(
  List<ExecutionEventRecord> records,
  String alias,
) => records
    .where(
      (ExecutionEventRecord record) =>
          record.event is ToolInvocationPrepared &&
          (record.event as ToolInvocationPrepared)
                  .invocation
                  .tool
                  .modelDefinition
                  .alias ==
              alias,
    )
    .map((ExecutionEventRecord preparedRecord) {
      final ToolInvocationPrepared prepared =
          preparedRecord.event as ToolInvocationPrepared;
      final ExecutionEventRecord terminalRecord = records.singleWhere(
        (ExecutionEventRecord record) => switch (record.event) {
          ToolExecutionCompleted(:final invocationId) ||
          ToolInvocationCompleted(
            :final invocationId,
          ) => invocationId == prepared.invocation.id,
          _ => false,
        },
      );
      return SourceCodingToolAttempt(
        preparedRecord: preparedRecord,
        terminalRecord: terminalRecord,
      );
    })
    .toList(growable: false);

/// Selects a pre-mutation read that exposed the target at the expected revision.
SourceCodingToolAttempt expectRelevantSourceRead({
  required Iterable<SourceCodingToolAttempt> reads,
  required int beforeSequence,
  required String relativePath,
  required String revision,
  required String originalFragment,
}) {
  expect(originalFragment, isNotEmpty);
  final List<SourceCodingToolAttempt> relevantReads = reads
      .where((attempt) {
        final Object? text = attempt.outcome.hostData['text'];
        return attempt.terminalRecord.sequence < beforeSequence &&
            attempt.outcome.disposition == ToolOutcomeDisposition.success &&
            attempt.prepared.invocation.canonicalArguments['relativePath'] ==
                relativePath &&
            attempt.outcome.hostData['revision'] == revision &&
            text is String &&
            text.contains(originalFragment);
      })
      .toList(growable: false);
  expect(
    relevantReads,
    isNotEmpty,
    reason:
        'A successful pre-patch read of $relativePath at the expected revision '
        'must expose the original source fragment to the model.',
  );
  return relevantReads.last;
}

void expectSuccessfulSourceCodingRun({
  required SourceCodingLiveResult result,
  required SessionEnvironmentAuthority authority,
  String? expectedEffectiveModel,
}) {
  final Object? failure = result.run.failure;
  expect(
    result.run.state,
    RunState.completed,
    reason: failure is ModelFailure
        ? '${failure.kind.name}: ${failure.providerCode}: '
              '${failure.providerMessage}: ${failure.providerDetails}'
        : failure?.toString(),
  );
  if (expectedEffectiveModel != null) {
    final List<String?> effectiveModels = result.run.journal.records
        .map((record) => record.event)
        .whereType<ModelInvocationSettled>()
        .where((event) => event.settlement == ModelSettlement.completed)
        .map((event) => event.metadata.effectiveModel)
        .toList(growable: false);
    print('ChatGPT source selected model: $expectedEffectiveModel');
    print(
      'ChatGPT source completed model invocations: ${effectiveModels.length}',
    );
    print('ChatGPT source service-reported effective models: $effectiveModels');
    expect(expectedEffectiveModel.trim(), isNotEmpty);
    expect(effectiveModels, isNotEmpty);
    expect(
      effectiveModels,
      everyElement(expectedEffectiveModel),
      reason:
          'Every completed ChatGPT invocation must report the selected model; '
          'missing or substituted model identity is not successful evidence.',
    );
  }
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

  expect(result.session.entries.last.role, 'assistant');
  final String answer = result.session.entries.last.content;
  expect(answer.trim(), isNotEmpty);
  expect(answer, contains(sourceCodingStrategyPath));
  expect(answer.toLowerCase(), anyOf(contains('40'), contains('forty')));
  if (expectedEffectiveModel != null) {
    print('ChatGPT source tool sequence: ${aliases.join(' -> ')}');
    print('ChatGPT source final assistant response: $answer');
  }
}

Future<void> _createSourceRepository({
  required String repository,
  required Directory source,
}) async {
  const List<String> sourcePaths = <String>[
    'README.md',
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
