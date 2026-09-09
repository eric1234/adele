import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/development/agent/agent_capability_adapters.dart';
import 'package:adele_desktop/development/agent/development_agent_support.dart';
import 'package:adele_desktop/development/agent/development_self_hosting.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

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
const String openAiApiKeyProviderId = developmentSelfHostingApiKeyProviderId;
const String openAiChatGptProviderId = developmentSelfHostingChatGptProviderId;
const String sourceCodingChatGptDefaultModel =
    developmentSelfHostingChatGptDefaultModel;

final class SourceCodingLiveArtifacts {
  const SourceCodingLiveArtifacts._(this.value);

  final DevelopmentSelfHostingArtifacts value;

  String get repository => value.repository.path;
  String get dartAotRuntime => value.dartAotRuntime;
  File get hostArtifact => value.hostArtifact;
  File get openAiArtifact => value.openAiArtifact;
  File get gitEnvironmentArtifact => value.gitEnvironmentArtifact;

  static Future<SourceCodingLiveArtifacts> compile(String scope) async {
    final Directory repository = Directory.current.parent;
    final Directory artifacts = Directory(
      '${repository.path}/.dart_tool/adele/integration/$scope',
    );
    return SourceCodingLiveArtifacts._(
      await DevelopmentSelfHostingArtifacts.compile(
        repository: repository,
        outputDirectory: artifacts,
      ),
    );
  }
}

final class SourceCodingLiveHarness {
  SourceCodingLiveHarness._({
    required DevelopmentSelfHostingTopology topology,
    required Directory container,
  }) : _topology = topology,
       _container = container;

  final DevelopmentSelfHostingTopology _topology;
  final Directory _container;

  bool _closed = false;

  PluginBackendHost get host => _topology.host;
  CapabilityRegistry get registry => _topology.registry;
  SessionId get sessionId => _topology.sessionId;
  SessionEnvironmentAuthority get authority => _topology.authority;
  ToolCatalog get catalog => _topology.catalog;

  static Future<SourceCodingLiveHarness> start({
    required SourceCodingLiveArtifacts artifacts,
    required Map<String, String> hostEnvironment,
    required String identity,
    required String taskTitle,
    bool enableCommandTools = false,
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
      final DevelopmentSelfHostingTopology topology =
          await DevelopmentSelfHostingTopology.start(
            artifacts: artifacts.value,
            projectSource: sourceRepository,
            hostEnvironment: hostEnvironment,
            identity: '$identity-source-live',
            taskTitle: taskTitle,
            includeCommandTools: enableCommandTools,
          );
      return SourceCodingLiveHarness._(
        topology: topology,
        container: container,
      );
    } catch (_) {
      if (await container.exists()) await container.delete(recursive: true);
      rethrow;
    }
  }

  Future<SourceCodingLiveResult> run({
    required String identity,
    required ModelProviderCapabilityAdapter model,
    String userPrompt = sourceCodingPrompt,
    String developmentInstructions = sourceCodingInstructions,
  }) async {
    final DevelopmentSelfHostingRunResult result =
        await executeDevelopmentSelfHostingRun(
          identity: '$identity-source-live',
          sessionId: sessionId,
          prompt: userPrompt,
          instructions: developmentInstructions,
          model: model,
          catalog: catalog,
          maxModelInvocations: 8,
        );
    if (result.executionFailure != null) {
      Error.throwWithStackTrace(
        result.executionFailure!,
        result.executionStackTrace!,
      );
    }
    return SourceCodingLiveResult(run: result.run, session: result.session);
  }

  String get projectSourcePath => _topology.projectSource.path;

  String get taskWorktreePath => _topology.taskWorktreePath;

  Future<String> readProjectSourceFile(String relativePath) =>
      File('${_topology.projectSource.path}/$relativePath').readAsString();

  Future<String> readTaskWorktreeFile(String relativePath) =>
      File('$taskWorktreePath/$relativePath').readAsString();

  Future<EnvironmentTextFile> readEnvironmentFile(String relativePath) =>
      _topology.environmentMaterialization.provider.readFile(
        authority.environmentId,
        relativePath,
      );

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await closeDevelopmentSelfHostingResources(<Future<void> Function()>[
      _topology.close,
      if (await _container.exists()) () => _container.delete(recursive: true),
    ]);
  }
}

Future<SourceCodingLiveProviderActivation> startOpenAiApiKeyProvider({
  required PluginBackendHost host,
  required CapabilityRegistry registry,
  required File artifact,
}) async {
  return SourceCodingLiveProviderActivation(
    await activateDevelopmentSelfHostingModelProvider(
      host: host,
      registry: registry,
      artifact: artifact,
      profile: DevelopmentSelfHostingProfile.apiKey,
    ),
  );
}

Map<String, String> sourceCodingChatGptHostEnvironment() {
  return DevelopmentSelfHostingProviderConfiguration.fromEnvironment(
    DevelopmentSelfHostingProfile.chatgpt,
  ).hostEnvironment;
}

String sourceCodingChatGptSelectedModel() {
  return DevelopmentSelfHostingProviderConfiguration.fromEnvironment(
    DevelopmentSelfHostingProfile.chatgpt,
  ).selectedModel;
}

Future<SourceCodingLiveProviderActivation> startOpenAiChatGptProvider({
  required PluginBackendHost host,
  required CapabilityRegistry registry,
  required File artifact,
}) async {
  return SourceCodingLiveProviderActivation(
    await activateDevelopmentSelfHostingModelProvider(
      host: host,
      registry: registry,
      artifact: artifact,
      profile: DevelopmentSelfHostingProfile.chatgpt,
    ),
  );
}

final class SourceCodingLiveProviderActivation {
  const SourceCodingLiveProviderActivation(this._activation);

  final DevelopmentSelfHostingProviderActivation _activation;

  Future<void> close() => _activation.close();
}

final class SourceCodingLiveResult {
  const SourceCodingLiveResult({required this.run, required this.session});

  final AgentRun run;
  final DevelopmentSessionHistory session;
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

  final String answer =
      (result.session.snapshot().entries.last as AssistantSessionMessage)
          .content;
  expect(answer.trim(), isNotEmpty);
  expect(answer, contains(sourceCodingStrategyPath));
  expect(answer.toLowerCase(), anyOf(contains('8'), contains('eight')));
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
