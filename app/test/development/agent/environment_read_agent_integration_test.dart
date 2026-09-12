import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/development/agent/development_agent_support.dart';
import 'package:adele_desktop/development/agent/development_self_hosting.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:search_tools_plugin/search_tools_plugin.dart';

import 'source_read_evidence_test_support.dart';

const String _gitEnvironmentPluginId = 'dev.adele.plugin.git-environment';
const String _gitEnvironmentProviderId = 'dev.adele.environment.git-worktree';
const String _sourceRelativePath =
    'plugins/chat_strategy/lib/chat_strategy_plugin.dart';
const String _transientSourceRelativePath =
    'app/lib/development/agent/phase_v_d1_transient_test_file.txt';
const String _transientSourceContent = 'transient ADELE content \u{1f642}\n';

void main() {
  late String repository;
  late String dartaotruntime;
  late File hostArtifact;
  late File gitEnvironmentArtifact;

  setUpAll(() async {
    repository = Directory.current.parent.path;
    final Directory artifacts = Directory(
      '$repository/.dart_tool/adele/integration/phase-v-a4-search-read',
    )..createSync(recursive: true);
    final String dart = _dartExecutable();
    dartaotruntime =
        '${File(dart).parent.path}/${Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime'}';
    hostArtifact = File('${artifacts.path}/host.aot');
    gitEnvironmentArtifact = File('${artifacts.path}/git-environment.aot');
    await Future.wait<void>(<Future<void>>[
      _compile(
        dart,
        '$repository/packages/plugin_backend_host/bin/adele_backend_host.dart',
        hostArtifact.path,
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
    'self-hosting topology stores its canonical Session strategy and authority',
    () async {
      final Directory container = await Directory.systemTemp.createTemp(
        'adele-self-hosting-topology-',
      );
      addTearDown(() async {
        if (await container.exists()) await container.delete(recursive: true);
      });
      final Directory source = Directory('${container.path}/source');
      await _createSourceRepository(repository: repository, source: source);
      final DevelopmentSelfHostingTopology topology =
          await DevelopmentSelfHostingTopology.start(
            artifacts: DevelopmentSelfHostingArtifacts(
              repository: Directory(repository),
              dartAotRuntime: dartaotruntime,
              directory: hostArtifact.parent,
              hostArtifact: hostArtifact,
              // Topology establishment does not activate a model provider.
              openAiArtifact: File(
                '${hostArtifact.parent.path}/unused-openai.aot',
              ),
              gitEnvironmentArtifact: gitEnvironmentArtifact,
            ),
            projectSource: source,
            hostEnvironment: const <String, String>{},
            identity: 'topology',
            taskTitle: 'Establish a canonical development Session',
          );
      addTearDown(topology.close);

      expect(topology.sessionId, SessionId('session-topology'));
      expect(topology.sessionId, topology.session.id);
      expect(topology.session.taskId, topology.task.id);
      expect(topology.session.strategyId, chatStrategyId);
      expect(
        topology.store.session(topology.sessionId),
        same(topology.session),
      );
      expect(
        topology.store.requireSessionAuthority(topology.sessionId),
        same(topology.authority),
      );
      expect(topology.authority.sessionId, topology.session.id);
      expect(topology.authority.taskId, topology.session.taskId);
      expect(topology.authority.environmentId, topology.environment.id);
      final ResolvedOrchestrationStrategy strategy = topology.lifecycle
          .resolveSessionStrategy(topology.sessionId);
      expect(strategy.strategyId, topology.session.strategyId);
      expect(strategy.validateBinding, returnsNormally);

      await topology.close();

      expect(
        () => topology.lifecycle.resolveSessionStrategy(topology.sessionId),
        throwsA(isA<OrchestrationStrategyUnavailable>()),
      );
      expect(
        topology.store.session(topology.sessionId),
        same(topology.session),
      );
      expect(topology.session.strategyId, chatStrategyId);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'agent searches then reads real source through Environment generations',
    () async {
      final Directory container = await Directory.systemTemp.createTemp(
        'adele-session-environment-read-',
      );
      addTearDown(() async {
        if (await container.exists()) await container.delete(recursive: true);
      });
      final Directory source = Directory('${container.path}/source');
      final String expectedSource = await _createSourceRepository(
        repository: repository,
        source: source,
      );
      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final CapabilityRegistry registry = CapabilityRegistry();
      final ProviderId providerId = ProviderId(_gitEnvironmentProviderId);
      final PluginCapabilityActivation environmentGenerationA =
          await _startGeneration(
            host: host,
            registry: registry,
            artifact: gitEnvironmentArtifact,
            providerId: providerId,
          );
      final InMemoryProductStore store = InMemoryProductStore();
      final ExtensionRegistry extensions = ExtensionRegistry();
      final ChatStrategyPlugin chat = ChatStrategyPlugin();
      final ExtensionRegistration strategyActivation = chat.activate(
        extensions,
      );
      addTearDown(strategyActivation.close);
      final ProductLifecycleCoordinator lifecycle =
          ProductLifecycleCoordinator.generated(
            store: store,
            registry: registry,
            extensions: extensions,
            ids: const _IntegrationIds('session-environment-read'),
          );
      final Project project = lifecycle.createProject(source.uri);
      final TaskCreationResult created = await lifecycle.createTask(
        projectId: project.id,
        title: 'Read real ADELE source',
        providerId: providerId,
      );
      final EnvironmentMaterialization materializationA = lifecycle
          .environmentRuntime
          .currentMaterialization(created.environment.id)!;
      final Session session = lifecycle.createSession(
        taskId: created.task.id,
        strategyId: chatStrategyId,
      );
      final SessionId sessionId = session.id;
      final SessionEnvironmentAuthority authority = store
          .requireSessionAuthority(sessionId);
      final ExtensionRegistration filesystemActivation =
          const FilesystemToolsPlugin().activate(extensions);
      addTearDown(filesystemActivation.close);
      final ExtensionRegistration searchGenerationA = const SearchToolsPlugin()
          .activate(extensions);
      final ToolCatalog catalogA = await buildModelToolCatalogForSession(
        sessionId: sessionId,
        environmentRuntime: lifecycle.environmentRuntime,
        extensions: extensions,
      );
      final MaterializedTool readFileA = catalogA.materialize().byAlias(
        'read_file',
      )!;
      final MaterializedTool searchA = catalogA.materialize().byAlias(
        'search',
      )!;
      final ChatSessionState history = chat.sessions.obtain(sessionId)
        ..instructions =
            'Search for and read the requested source before answering.'
        ..append(
          ChatUserMessage('Inspect the maintained ADELE strategy source.'),
        );
      final _SearchReadModel model = _SearchReadModel();
      final SessionOrchestrationRun strategy = createSessionOrchestrationRun(
        lifecycle: lifecycle,
        sessionId: sessionId,
        runId: RunId('run-environment-read'),
        contextComposer: InferenceContextComposer(extensions),
        model: model,
        toolCatalog: catalogA,
        policy: const DevelopmentToolPolicy(ToolPolicyDecision.allow),
      );
      final AgentRun run = strategy.run;

      await strategy.start();

      expect(run.state, RunState.completed);
      expect(authority.environmentId, created.environment.id);
      expect(model.invocations, 3);
      expect(model.receivedRealSource, isTrue);
      expect(model.discoveredPath, _sourceRelativePath);
      expect(strategy.lastToolOutcome?.hostData['text'], expectedSource);
      expect(
        (history.snapshot().entries.last as ChatAssistantMessage).content,
        allOf(contains(_sourceRelativePath), contains('8')),
      );

      await searchGenerationA.close();
      expect(
        searchA.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      expect(readFileA.executable.validateBinding, returnsNormally);
      final ToolCatalog inactiveCatalog = await buildModelToolCatalogForSession(
        sessionId: sessionId,
        environmentRuntime: lifecycle.environmentRuntime,
        extensions: extensions,
      );
      expect(
        inactiveCatalog.materialize().tools.map(
          (tool) => tool.modelDefinition.alias,
        ),
        <String>['read_file', 'apply_patch', 'create_file', 'delete_file'],
      );

      final ExtensionRegistration searchGenerationB = const SearchToolsPlugin()
          .activate(extensions);
      addTearDown(searchGenerationB.close);
      final ToolCatalog pluginGenerationBCatalog =
          await buildModelToolCatalogForSession(
            sessionId: sessionId,
            environmentRuntime: lifecycle.environmentRuntime,
            extensions: extensions,
          );
      final MaterializedTool searchB = pluginGenerationBCatalog
          .materialize()
          .byAlias('search')!;
      expect(searchB.executable.validateBinding, returnsNormally);
      expect(
        searchA.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      expect(
        (await _executeSearch(searchB, sessionId)).hostData['matches'],
        isNotEmpty,
      );

      await environmentGenerationA.close();
      expect(
        searchB.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      expect(
        readFileA.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      final PluginCapabilityActivation environmentGenerationB =
          await _startGeneration(
            host: host,
            registry: registry,
            artifact: gitEnvironmentArtifact,
            providerId: providerId,
          );
      addTearDown(environmentGenerationB.close);
      expect(
        readFileA.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );

      final ToolCatalog catalogB = await buildModelToolCatalogForSession(
        sessionId: sessionId,
        environmentRuntime: lifecycle.environmentRuntime,
        extensions: extensions,
      );
      final EnvironmentMaterialization materializationB = lifecycle
          .environmentRuntime
          .currentMaterialization(created.environment.id)!;
      final MaterializedTool readFileB = catalogB.materialize().byAlias(
        'read_file',
      )!;
      final MaterializedTool searchC = catalogB.materialize().byAlias(
        'search',
      )!;
      const String siblingPath = 'plugins/chat_strategy/lib/scope-decoy.txt';
      final String worktreePath =
          created.environment.providerState!['worktreePath']! as String;
      await File(
        '$worktreePath/$siblingPath',
      ).writeAsString('final class ChatSessionState decoy\n');
      final ToolOutcome restoredSearch = await _executeSearch(
        searchC,
        sessionId,
      );

      expect(materializationB, isNot(same(materializationA)));
      expect(materializationB.environment.id, materializationA.environment.id);
      expect(restoredSearch.disposition, ToolOutcomeDisposition.success);
      expect(restoredSearch.hostData['path'], 'plugins/chat_strategy/lib');
      final ToolOutcome missingScope = await _executeSearch(
        searchC,
        sessionId,
        path: 'missing-directory',
      );
      expect(missingScope.disposition, ToolOutcomeDisposition.failure);
      expect(missingScope.failureKind, ToolFailureKind.domain);
      expect(missingScope.hostData['path'], 'missing-directory');
      expect(missingScope.hostData['code'], 'not_found');
      expect(
        missingScope.hostData['environmentId'],
        authority.environmentId.value,
      );
      expect(missingScope.hostData['matches'], isEmpty);

      final ToolOutcome fileScope = await _executeSearch(
        searchC,
        sessionId,
        path: _sourceRelativePath,
      );
      final List<String> sourceLines = const LineSplitter().convert(
        expectedSource,
      );
      final int matchingLine = sourceLines.indexOf(
        'final class ChatSessionState {',
      );
      expect(matchingLine, isNonNegative);
      final Map<String, Object?> expectedMatch = <String, Object?>{
        'relativePath': _sourceRelativePath,
        'lineNumber': matchingLine + 1,
        'snippet': sourceLines[matchingLine],
      };
      expect(fileScope.disposition, ToolOutcomeDisposition.success);
      expect(fileScope.effectCertainty, EffectCertainty.knownOccurred);
      expect(fileScope.hostData['path'], _sourceRelativePath);
      expect(fileScope.hostData['query'], 'final class ChatSessionState');
      expect(
        fileScope.hostData['environmentId'],
        authority.environmentId.value,
      );
      expect(fileScope.hostData['matches'], <Object?>[expectedMatch]);
      expect(fileScope.hostData['truncated'], false);
      expect(fileScope.hostData['incomplete'], false);
      expect(fileScope.hostData['stopReason'], isNull);
      expect(fileScope.hostData['entriesVisited'], 0);
      expect(
        fileScope.hostData['searchedBytes'],
        utf8.encode(expectedSource).length,
      );
      expect(
        fileScope.modelContent,
        'Search results:\nScope: ${jsonEncode(_sourceRelativePath)}\n'
        '${jsonEncode(expectedMatch)}',
      );
      expect(
        restoredSearch.hostData['matches'],
        contains(
          equals(<String, Object?>{
            'relativePath': siblingPath,
            'lineNumber': 1,
            'snippet': 'final class ChatSessionState decoy',
          }),
        ),
      );
      expect(await File('${source.path}/$siblingPath').exists(), false);
      expect(
        await File('$worktreePath/$_sourceRelativePath').readAsString(),
        expectedSource,
      );
      expect(
        await File('${source.path}/$_sourceRelativePath').readAsString(),
        expectedSource,
      );
      expect(
        restoredSearch.hostData['matches'],
        contains(
          isA<Map<String, Object?>>().having(
            (match) => match['relativePath'],
            'relativePath',
            _sourceRelativePath,
          ),
        ),
      );
      expect(readFileB.executable.validateBinding, returnsNormally);
      expect(
        searchA.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      expect(
        searchB.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );

      await environmentGenerationB.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'agent applies ordered edits then validates source in its Session Environment',
    () async {
      final Directory container = await Directory.systemTemp.createTemp(
        'adele-session-environment-patch-',
      );
      addTearDown(() async {
        if (await container.exists()) await container.delete(recursive: true);
      });
      final Directory source = Directory('${container.path}/source');
      final String originalSource = await _createSourceRepository(
        repository: repository,
        source: source,
      );
      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final CapabilityRegistry registry = CapabilityRegistry();
      final ProviderId providerId = ProviderId(_gitEnvironmentProviderId);
      final PluginCapabilityActivation environmentActivation =
          await _startGeneration(
            host: host,
            registry: registry,
            artifact: gitEnvironmentArtifact,
            providerId: providerId,
          );
      addTearDown(environmentActivation.close);
      final InMemoryProductStore store = InMemoryProductStore();
      final ExtensionRegistry extensions = ExtensionRegistry();
      final ChatStrategyPlugin chat = ChatStrategyPlugin();
      final ExtensionRegistration strategyActivation = chat.activate(
        extensions,
      );
      addTearDown(strategyActivation.close);
      final ProductLifecycleCoordinator lifecycle =
          ProductLifecycleCoordinator.generated(
            store: store,
            registry: registry,
            extensions: extensions,
            ids: const _IntegrationIds('session-environment-patch'),
          );
      final Project project = lifecycle.createProject(source.uri);
      final TaskCreationResult created = await lifecycle.createTask(
        projectId: project.id,
        title: 'Patch real ADELE source',
        providerId: providerId,
      );
      final Session session = lifecycle.createSession(
        taskId: created.task.id,
        strategyId: chatStrategyId,
      );
      final SessionId sessionId = session.id;
      final SessionEnvironmentAuthority authority = store
          .requireSessionAuthority(sessionId);
      final ExtensionRegistration filesystemActivation =
          const FilesystemToolsPlugin().activate(extensions);
      addTearDown(filesystemActivation.close);
      final ExtensionRegistration commandActivation = const CommandToolsPlugin()
          .activate(extensions);
      addTearDown(commandActivation.close);
      final ToolCatalog catalog = await buildModelToolCatalogForSession(
        sessionId: sessionId,
        environmentRuntime: lifecycle.environmentRuntime,
        extensions: extensions,
      );
      final MaterializedToolSet tools = catalog.materialize();
      final _ReadPatchCommandModel model = _ReadPatchCommandModel();
      final ChatSessionState history = chat.sessions.obtain(sessionId)
        ..instructions =
            'Read the requested source, use its visible revision for one '
            'apply_patch call with ordered exact edits, validate it with '
            'git diff --check using direct arguments, then report the result.'
        ..append(ChatUserMessage('Update the strategy default safely.'));
      final SessionOrchestrationRun strategy = createSessionOrchestrationRun(
        lifecycle: lifecycle,
        sessionId: sessionId,
        runId: RunId('run-environment-patch'),
        contextComposer: InferenceContextComposer(extensions),
        model: model,
        toolCatalog: catalog,
        policy: const DevelopmentToolPolicy(ToolPolicyDecision.allow),
      );
      final AgentRun run = strategy.run;

      expect(tools.tools.map((tool) => tool.modelDefinition.alias), <String>[
        'read_file',
        'apply_patch',
        'create_file',
        'delete_file',
        'run_command',
      ]);
      for (final MaterializedTool tool in tools.tools) {
        final Object? properties =
            tool.modelDefinition.argumentsSchema['properties'];
        expect(properties, isA<Map<String, Object?>>());
        expect(
          (properties! as Map<String, Object?>).keys,
          isNot(contains('environmentId')),
        );
      }

      await strategy.start();

      expect(run.state, RunState.completed);
      expect(model.invocations, 4);
      expect(model.observedPath, _sourceRelativePath);
      expect(
        model.observedSource,
        originalSource.substring(originalSource.indexOf('\n') + 1),
      );
      expect(model.expectedRevision, isNotEmpty);
      expect(model.postWriteRevision, isNot(model.expectedRevision));
      expect(model.commandResultValidated, isTrue);
      expect(authority.environmentId, created.environment.id);
      expect(
        (history.snapshot().entries.last as ChatAssistantMessage).content,
        allOf(
          contains('maxModelInvocations to 9'),
          contains('git diff --check exited with code 0'),
        ),
      );

      final List<ToolInvocationPrepared> prepared = run.journal.records
          .map((record) => record.event)
          .whereType<ToolInvocationPrepared>()
          .toList(growable: false);
      expect(
        prepared.map((event) => event.invocation.tool.modelDefinition.alias),
        <String>['read_file', 'apply_patch', 'run_command'],
      );
      expect(model.edits, hasLength(2));
      expect(model.edits.last['search'], model.edits.first['replace']);
      expect(
        originalSource,
        isNot(contains(model.edits.last['search']! as String)),
      );
      expect(prepared[1].invocation.canonicalArguments, <String, Object?>{
        'relativePath': _sourceRelativePath,
        'expectedRevision': model.expectedRevision,
        'edits': model.edits,
      });
      expect(
        prepared[1].invocation.proposal.arguments,
        prepared[1].invocation.canonicalArguments,
      );
      expect(prepared.last.invocation.proposal.arguments, <String, Object?>{
        'program': 'git',
        'arguments': <Object?>['diff', '--check'],
        'workingDirectory': '',
        'timeoutSeconds': 30,
      });
      expect(prepared.last.invocation.canonicalArguments, <String, Object?>{
        'program': 'git',
        'arguments': <Object?>['diff', '--check'],
        'workingDirectory': '',
        'timeoutSeconds': 30,
      });
      final List<ToolExecutionCompleted> completed = run.journal.records
          .map((record) => record.event)
          .whereType<ToolExecutionCompleted>()
          .toList(growable: false);
      expect(completed, hasLength(3));
      expect(
        completed.map((event) => event.outcome.disposition),
        everyElement(ToolOutcomeDisposition.success),
      );
      expect(
        completed.map((event) => event.outcome.hostData['environmentId']),
        everyElement(authority.environmentId.value),
      );
      expect(
        completed.first.outcome.hostData['revision'],
        model.expectedRevision,
      );
      expect(completed.first.outcome.hostData['text'], model.observedSource);
      expect(completed.first.outcome.hostData['startLine'], 2);
      expectSourceReadEvidence(
        arguments: prepared.first.invocation.canonicalArguments,
        outcome: completed.first.outcome,
        originalText: originalSource,
        relativePath: _sourceRelativePath,
        revision: model.expectedRevision!,
      );
      expect(
        completed.first.outcome.hostData['sizeBytes'],
        utf8.encode(originalSource).length,
      );
      expect(completed[1].outcome.hostData, <String, Object?>{
        'environmentId': authority.environmentId.value,
        'relativePath': _sourceRelativePath,
        'editCount': model.edits.length,
        'newRevision': model.postWriteRevision,
      });
      expect(
        completed[1].outcome.modelContent,
        'Patched: ${jsonEncode(_sourceRelativePath)}\n'
        'Edits applied: ${model.edits.length}\n'
        'Revision: ${jsonEncode(model.postWriteRevision)}',
      );
      expect(completed.last.outcome.hostData['termination'], 'exited');
      expect(completed.last.outcome.hostData['exitCode'], 0);
      expect(completed.last.outcome.hostData['program'], 'git');
      expect(completed.last.outcome.hostData['arguments'], <Object?>[
        'diff',
        '--check',
      ]);
      final List<ToolPolicyEvaluated> policyEvaluations = run.journal.records
          .map((record) => record.event)
          .whereType<ToolPolicyEvaluated>()
          .toList(growable: false);
      expect(policyEvaluations, hasLength(3));
      expect(policyEvaluations.last.decision, ToolPolicyDecision.allow);
      expect(policyEvaluations[1].effects.effects, <ToolEffect>{
        ToolEffect.sourceMutation,
      });
      expect(
        policyEvaluations[1].effects.targets.single.uri.toString(),
        'adele-environment:/${authority.environmentId.value}/'
        '$_sourceRelativePath',
      );
      expect(policyEvaluations.last.effects.effects, <ToolEffect>{
        ToolEffect.processExecution,
      });
      expect(
        policyEvaluations.last.effects.uncertainty,
        EffectUncertainty.uncertain,
      );
      expect(
        policyEvaluations.last.effects.targets.single.uri.toString(),
        'adele-environment:/${authority.environmentId.value}/',
      );
      expect(
        policyEvaluations.last.effects.summary,
        contains('Run program "git" with arguments ["diff","--check"]'),
      );

      final ExecutionEventRecord readCompleted = run.journal.records
          .singleWhere(
            (ExecutionEventRecord record) =>
                record.event is ToolExecutionCompleted &&
                (record.event as ToolExecutionCompleted).invocationId ==
                    prepared.first.invocation.id,
          );
      final ExecutionEventRecord patchPrepared = run.journal.records
          .singleWhere(
            (ExecutionEventRecord record) =>
                record.event is ToolInvocationPrepared &&
                (record.event as ToolInvocationPrepared).invocation.id ==
                    prepared[1].invocation.id,
          );
      final ExecutionEventRecord patchCompleted = run.journal.records
          .singleWhere(
            (ExecutionEventRecord record) =>
                record.event is ToolExecutionCompleted &&
                (record.event as ToolExecutionCompleted).invocationId ==
                    prepared[1].invocation.id,
          );
      final ExecutionEventRecord commandStarted = run.journal.records
          .singleWhere(
            (ExecutionEventRecord record) =>
                record.event is ToolExecutionStarted &&
                (record.event as ToolExecutionStarted).invocationId ==
                    prepared.last.invocation.id,
          );
      final ExecutionEventRecord commandCompleted = run.journal.records
          .singleWhere(
            (ExecutionEventRecord record) =>
                record.event is ToolExecutionCompleted &&
                (record.event as ToolExecutionCompleted).invocationId ==
                    prepared.last.invocation.id,
          );
      final ExecutionEventRecord finalModelStarted = run.journal.records
          .where(
            (ExecutionEventRecord record) =>
                record.event is ModelInvocationStarted,
          )
          .last;
      expect(readCompleted.sequence, lessThan(patchPrepared.sequence));
      expect(patchPrepared.sequence, lessThan(patchCompleted.sequence));
      expect(patchCompleted.sequence, lessThan(commandStarted.sequence));
      expect(commandStarted.sequence, lessThan(commandCompleted.sequence));
      expect(commandCompleted.sequence, lessThan(finalModelStarted.sequence));

      final EnvironmentMaterialization materialization = lifecycle
          .environmentRuntime
          .currentMaterialization(created.environment.id)!;
      final EnvironmentTextFile resultingFile = await materialization.provider
          .readFile(created.environment.id, _sourceRelativePath);
      final String expectedTaskSource = originalSource.replaceFirst(
        '_maxModelInvocations = 8',
        '_maxModelInvocations = 9',
      );
      expect(resultingFile.text, expectedTaskSource);
      expect(resultingFile.revision, model.postWriteRevision);
      final String worktreePath =
          created.environment.providerState!['worktreePath']! as String;
      final File worktreeSource = File('$worktreePath/$_sourceRelativePath');
      expect(await worktreeSource.readAsString(), resultingFile.text);
      expect(
        worktreeSource.path,
        isNot(File('${source.path}/$_sourceRelativePath').path),
      );
      final String unchangedProjectSource = await File(
        '${source.path}/$_sourceRelativePath',
      ).readAsString();
      expect(unchangedProjectSource, originalSource);
      expect(unchangedProjectSource, contains('_maxModelInvocations = 8'));
      expect(
        unchangedProjectSource,
        isNot(contains('_maxModelInvocations = 9')),
      );

      await environmentActivation.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'agent creates reads and deletes a transient Environment source file',
    () async {
      final Directory container = await Directory.systemTemp.createTemp(
        'adele-session-environment-create-delete-',
      );
      addTearDown(() async {
        if (await container.exists()) await container.delete(recursive: true);
      });
      final Directory source = Directory('${container.path}/source');
      await _createSourceRepository(repository: repository, source: source);
      final File projectTarget = File(
        '${source.path}/$_transientSourceRelativePath',
      );
      final File checkoutTarget = File(
        '$repository/$_transientSourceRelativePath',
      );
      expect(await projectTarget.exists(), isFalse);
      expect(await checkoutTarget.exists(), isFalse);

      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final CapabilityRegistry registry = CapabilityRegistry();
      final ProviderId providerId = ProviderId(_gitEnvironmentProviderId);
      final PluginCapabilityActivation environmentActivation =
          await _startGeneration(
            host: host,
            registry: registry,
            artifact: gitEnvironmentArtifact,
            providerId: providerId,
          );
      addTearDown(environmentActivation.close);
      final InMemoryProductStore store = InMemoryProductStore();
      final ExtensionRegistry extensions = ExtensionRegistry();
      final ChatStrategyPlugin chat = ChatStrategyPlugin();
      final ExtensionRegistration strategyActivation = chat.activate(
        extensions,
      );
      addTearDown(strategyActivation.close);
      final ProductLifecycleCoordinator lifecycle =
          ProductLifecycleCoordinator.generated(
            store: store,
            registry: registry,
            extensions: extensions,
            ids: const _IntegrationIds('session-environment-create-delete'),
          );
      final Project project = lifecycle.createProject(source.uri);
      final TaskCreationResult created = await lifecycle.createTask(
        projectId: project.id,
        title: 'Create and delete transient source',
        providerId: providerId,
      );
      final Session session = lifecycle.createSession(
        taskId: created.task.id,
        strategyId: chatStrategyId,
      );
      final SessionId sessionId = session.id;
      final SessionEnvironmentAuthority authority = store
          .requireSessionAuthority(sessionId);
      final ExtensionRegistration filesystemActivation =
          const FilesystemToolsPlugin().activate(extensions);
      addTearDown(filesystemActivation.close);
      final ToolCatalog catalog = await buildModelToolCatalogForSession(
        sessionId: sessionId,
        environmentRuntime: lifecycle.environmentRuntime,
        extensions: extensions,
      );
      final MaterializedToolSet tools = catalog.materialize();
      expect(tools.tools.map((tool) => tool.modelDefinition.alias), <String>[
        'read_file',
        'apply_patch',
        'create_file',
        'delete_file',
      ]);
      final String worktreePath =
          created.environment.providerState!['worktreePath']! as String;
      final File taskTarget = File(
        '$worktreePath/$_transientSourceRelativePath',
      );
      bool taskOnlyExistenceObserved = false;
      final _CreateReadDeleteModel model = _CreateReadDeleteModel(
        beforeDelete: () async {
          expect(await taskTarget.readAsString(), _transientSourceContent);
          expect(await projectTarget.exists(), isFalse);
          expect(await checkoutTarget.exists(), isFalse);
          taskOnlyExistenceObserved = true;
        },
      );
      final ChatSessionState history = chat.sessions.obtain(sessionId)
        ..instructions =
            'Create the requested new file, read it, use the read result '
            'Revision to delete it safely, then report completion.'
        ..append(
          ChatUserMessage('Create, verify, and remove the transient file.'),
        );
      final SessionOrchestrationRun strategy = createSessionOrchestrationRun(
        lifecycle: lifecycle,
        sessionId: sessionId,
        runId: RunId('run-environment-create-delete'),
        contextComposer: InferenceContextComposer(extensions),
        model: model,
        toolCatalog: catalog,
        policy: const DevelopmentToolPolicy(ToolPolicyDecision.allow),
      );
      final AgentRun run = strategy.run;

      await strategy.start();

      expect(run.state, RunState.completed);
      expect(model.invocations, 4);
      expect(model.createdPath, _transientSourceRelativePath);
      expect(model.readPath, _transientSourceRelativePath);
      expect(model.observedContent, _transientSourceContent);
      expect(model.createdRevision, isNotEmpty);
      expect(model.readRevision, model.createdRevision);
      expect(model.deleteExpectedRevision, model.readRevision);
      expect(model.deleteResultConsumed, isTrue);
      expect(taskOnlyExistenceObserved, isTrue);
      expect(authority.environmentId, created.environment.id);
      expect(
        (history.snapshot().entries.last as ChatAssistantMessage).content,
        contains('created, verified, and deleted'),
      );

      final List<ExecutionEventRecord> preparedRecords = run.journal.records
          .where((record) => record.event is ToolInvocationPrepared)
          .toList(growable: false);
      final List<ToolInvocationPrepared> prepared = preparedRecords
          .map((record) => record.event as ToolInvocationPrepared)
          .toList(growable: false);
      expect(
        prepared.map((event) => event.invocation.tool.modelDefinition.alias),
        <String>['create_file', 'read_file', 'delete_file'],
      );
      expect(
        prepared.last.invocation.canonicalArguments['expectedRevision'],
        model.readRevision,
      );
      expect(
        prepared.last.invocation.proposal.arguments['expectedRevision'],
        model.readRevision,
      );

      final List<ExecutionEventRecord> completedRecords = run.journal.records
          .where((record) => record.event is ToolExecutionCompleted)
          .toList(growable: false);
      final List<ToolExecutionCompleted> completed = completedRecords
          .map((record) => record.event as ToolExecutionCompleted)
          .toList(growable: false);
      expect(completed, hasLength(3));
      expect(
        completed.map((event) => event.outcome.disposition),
        everyElement(ToolOutcomeDisposition.success),
      );
      expect(
        completed.map((event) => event.outcome.effectCertainty),
        everyElement(EffectCertainty.knownOccurred),
      );
      expect(
        completed.map((event) => event.outcome.hostData['environmentId']),
        everyElement(authority.environmentId.value),
      );
      expect(
        completed.first.outcome.hostData['revision'],
        model.createdRevision,
      );
      expect(completed[1].outcome.hostData['revision'], model.readRevision);
      expect(completed[1].outcome.hostData['text'], _transientSourceContent);

      final List<ToolPolicyEvaluated> policy = run.journal.records
          .map((record) => record.event)
          .whereType<ToolPolicyEvaluated>()
          .toList(growable: false);
      expect(policy, hasLength(3));
      expect(
        policy.map((event) => event.decision),
        everyElement(ToolPolicyDecision.allow),
      );
      expect(policy[0].effects.effects, <ToolEffect>{
        ToolEffect.sourceMutation,
      });
      expect(policy[1].effects.effects, <ToolEffect>{ToolEffect.sourceRead});
      expect(policy[2].effects.effects, <ToolEffect>{
        ToolEffect.sourceMutation,
      });
      expect(
        policy.map((event) => event.effects.uncertainty),
        everyElement(EffectUncertainty.none),
      );
      final String expectedTarget =
          'adele-environment:/${authority.environmentId.value}/'
          '$_transientSourceRelativePath';
      expect(
        policy.map((event) => event.effects.targets.single.uri.toString()),
        everyElement(expectedTarget),
      );

      final ExecutionEventRecord createCompleted = completedRecords.first;
      final ExecutionEventRecord readPrepared = preparedRecords[1];
      final ExecutionEventRecord readCompleted = completedRecords[1];
      final ExecutionEventRecord deletePrepared = preparedRecords[2];
      final ExecutionEventRecord deleteCompleted = completedRecords[2];
      final ExecutionEventRecord finalModelStarted = run.journal.records
          .where((record) => record.event is ModelInvocationStarted)
          .last;
      expect(createCompleted.sequence, lessThan(readPrepared.sequence));
      expect(readPrepared.sequence, lessThan(readCompleted.sequence));
      expect(readCompleted.sequence, lessThan(deletePrepared.sequence));
      expect(deletePrepared.sequence, lessThan(deleteCompleted.sequence));
      expect(deleteCompleted.sequence, lessThan(finalModelStarted.sequence));

      expect(await taskTarget.exists(), isFalse);
      expect(await projectTarget.exists(), isFalse);
      expect(await checkoutTarget.exists(), isFalse);

      await environmentActivation.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

final class _SearchReadModel implements ModelPort {
  int invocations = 0;
  bool receivedRealSource = false;
  String? discoveredPath;

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    invocations++;
    final List<SemanticToolOutcomeInput> outcomes = request.input
        .whereType<SemanticToolOutcomeInput>()
        .toList(growable: false);
    if (outcomes.isEmpty) {
      final MaterializedTool search = request.tools.byAlias('search')!;
      final MaterializedTool readFile = request.tools.byAlias('read_file')!;
      final Object? searchProperties =
          search.modelDefinition.argumentsSchema['properties'];
      final Object? readProperties =
          readFile.modelDefinition.argumentsSchema['properties'];
      if (searchProperties is! Map<String, Object?> ||
          searchProperties.keys.toSet().difference(<String>{
            'query',
            'path',
          }).isNotEmpty ||
          searchProperties.length != 2 ||
          readProperties is! Map<String, Object?> ||
          readProperties.keys.toSet().difference(<String>{
            'relativePath',
            'startLine',
            'lineCount',
          }).isNotEmpty ||
          readProperties.length != 3) {
        throw StateError(
          'Stock tools exposed Environment selection to the model.',
        );
      }
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelToolProposalOutput(
          ProviderToolProposal(
            providerCallId: 'search-call-1',
            alias: 'search',
            arguments: const <String, Object?>{
              'query': 'final class ChatSessionState',
              'path': './plugins/chat_strategy//lib/',
            },
          ),
        ),
      );
    } else if (outcomes.length == 1) {
      final List<String> encodedMatches = outcomes.single.outcome.modelContent
          .split('\n')
          .where((String line) => line.startsWith('{'))
          .toList(growable: false);
      if (encodedMatches.length != 1) {
        throw StateError(
          'Search did not identify exactly one maintained file.',
        );
      }
      final Object? decodedMatch = jsonDecode(encodedMatches.single);
      if (decodedMatch is! Map<String, Object?> ||
          decodedMatch['relativePath'] is! String) {
        throw StateError('Search returned an invalid model-visible match.');
      }
      discoveredPath = decodedMatch['relativePath']! as String;
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelToolProposalOutput(
          ProviderToolProposal(
            providerCallId: 'read-call-1',
            alias: 'read_file',
            arguments: <String, Object?>{'relativePath': discoveredPath},
          ),
        ),
      );
    } else {
      final String content = outcomes.last.outcome.modelContent;
      receivedRealSource =
          content.contains('final class ChatSessionState') &&
          content.contains('_maxModelInvocations = 8');
      if (!receivedRealSource) {
        throw StateError(
          'The model did not receive real ADELE source content.',
        );
      }
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelTextOutput(
          '$discoveredPath declares ChatSessionState and defaults maxModelInvocations to 8.',
        ),
      );
    }
    yield ModelInvocationSettledEvent(
      invocationId: request.invocationId,
      settlement: ModelSettlement.completed,
      metadata: ModelTerminalMetadata(
        effectiveModel: 'deterministic-search-read-v1',
      ),
    );
  }
}

final class _ReadPatchCommandModel implements ModelPort {
  int invocations = 0;
  String? observedPath;
  String? observedSource;
  String? expectedRevision;
  String? postWriteRevision;
  late List<Map<String, Object?>> edits;
  bool commandResultValidated = false;

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    invocations++;
    final List<String> modelVisibleOutcomes = request.input
        .whereType<SemanticToolOutcomeInput>()
        .map((input) => input.outcome.modelContent)
        .toList(growable: false);
    if (modelVisibleOutcomes.isEmpty) {
      final MaterializedTool readFile = request.tools.byAlias('read_file')!;
      final MaterializedTool applyPatch = request.tools.byAlias('apply_patch')!;
      _requireModelSchema(
        readFile,
        expectedProperties: const <String>{
          'relativePath',
          'startLine',
          'lineCount',
        },
      );
      expect(
        applyPatch.modelDefinition.argumentsSchema,
        const <String, Object?>{
          'type': 'object',
          'required': <Object?>['relativePath', 'expectedRevision', 'edits'],
          'properties': <String, Object?>{
            'relativePath': <String, Object?>{'type': 'string'},
            'expectedRevision': <String, Object?>{'type': 'string'},
            'edits': <String, Object?>{
              'type': 'array',
              'minItems': 1,
              'items': <String, Object?>{
                'type': 'object',
                'required': <Object?>['search', 'replace'],
                'properties': <String, Object?>{
                  'search': <String, Object?>{'type': 'string', 'minLength': 1},
                  'replace': <String, Object?>{'type': 'string'},
                },
                'additionalProperties': false,
              },
            },
          },
          'additionalProperties': false,
        },
      );
      _requireModelSchema(
        request.tools.byAlias('run_command')!,
        expectedProperties: const <String>{
          'program',
          'arguments',
          'workingDirectory',
          'timeoutSeconds',
        },
      );
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelToolProposalOutput(
          ProviderToolProposal(
            providerCallId: 'read-call-mutation',
            alias: 'read_file',
            arguments: const <String, Object?>{
              'relativePath': _sourceRelativePath,
              'startLine': 2,
            },
          ),
        ),
      );
    } else if (modelVisibleOutcomes.length == 1) {
      final _VisibleFile file = _parseVisibleFile(modelVisibleOutcomes.single);
      observedPath = file.relativePath;
      observedSource = file.text;
      expectedRevision = file.revision;
      final List<String> candidateLines = file.text
          .split('\n')
          .where((line) => line.contains('_maxModelInvocations = 8'))
          .toList(growable: false);
      if (candidateLines.length != 1) {
        throw StateError(
          'The model-visible source did not contain one patch target line.',
        );
      }
      final String search = candidateLines.single;
      final String intermediate = search.replaceFirst(
        '_maxModelInvocations = 8',
        '_maxModelInvocations = 10',
      );
      final String replace = search.replaceFirst(
        '_maxModelInvocations = 8',
        '_maxModelInvocations = 9',
      );
      edits = <Map<String, Object?>>[
        <String, Object?>{'search': search, 'replace': intermediate},
        <String, Object?>{'search': intermediate, 'replace': replace},
      ];
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelToolProposalOutput(
          ProviderToolProposal(
            providerCallId: 'patch-call-mutation',
            alias: 'apply_patch',
            arguments: <String, Object?>{
              'relativePath': file.relativePath,
              'expectedRevision': file.revision,
              'edits': edits,
            },
          ),
        ),
      );
    } else if (modelVisibleOutcomes.length == 2) {
      final _VisiblePatch result = _parseVisiblePatch(
        modelVisibleOutcomes.last,
      );
      if (result.relativePath != observedPath) {
        throw StateError('The patch result named another file.');
      }
      if (result.editCount != edits.length) {
        throw StateError('The patch result did not apply every ordered edit.');
      }
      postWriteRevision = result.revision;
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelToolProposalOutput(
          ProviderToolProposal(
            providerCallId: 'command-call-mutation',
            alias: 'run_command',
            arguments: const <String, Object?>{
              'program': 'git',
              'arguments': <Object?>['diff', '--check'],
              'workingDirectory': '',
              'timeoutSeconds': 30,
            },
          ),
        ),
      );
    } else if (modelVisibleOutcomes.length == 3) {
      commandResultValidated = _isSuccessfulVisibleGitDiffCheck(
        modelVisibleOutcomes.last,
      );
      if (!commandResultValidated) {
        throw StateError(
          'The model-visible command result did not prove validation success.',
        );
      }
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelTextOutput(
          'Patched $observedPath, changed maxModelInvocations to 9, and '
          'git diff --check exited with code 0.',
        ),
      );
    } else {
      throw StateError('Unexpected deterministic model continuation.');
    }
    yield ModelInvocationSettledEvent(
      invocationId: request.invocationId,
      settlement: ModelSettlement.completed,
      metadata: ModelTerminalMetadata(
        effectiveModel: 'deterministic-read-patch-command-v1',
      ),
    );
  }
}

final class _CreateReadDeleteModel implements ModelPort {
  _CreateReadDeleteModel({required this.beforeDelete});

  final Future<void> Function() beforeDelete;
  int invocations = 0;
  String? createdPath;
  String? createdRevision;
  String? readPath;
  String? readRevision;
  String? observedContent;
  String? deleteExpectedRevision;
  bool deleteResultConsumed = false;

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    invocations++;
    final List<String> modelVisibleOutcomes = request.input
        .whereType<SemanticToolOutcomeInput>()
        .map((input) => input.outcome.modelContent)
        .toList(growable: false);
    if (modelVisibleOutcomes.isEmpty) {
      _requireModelSchema(
        request.tools.byAlias('create_file')!,
        expectedProperties: const <String>{'relativePath', 'content'},
      );
      _requireModelSchema(
        request.tools.byAlias('read_file')!,
        expectedProperties: const <String>{
          'relativePath',
          'startLine',
          'lineCount',
        },
      );
      _requireModelSchema(
        request.tools.byAlias('delete_file')!,
        expectedProperties: const <String>{'relativePath', 'expectedRevision'},
      );
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelToolProposalOutput(
          ProviderToolProposal(
            providerCallId: 'create-call-d1',
            alias: 'create_file',
            arguments: const <String, Object?>{
              'relativePath': _transientSourceRelativePath,
              'content': _transientSourceContent,
            },
          ),
        ),
      );
    } else if (modelVisibleOutcomes.length == 1) {
      final _VisibleCreation creation = _parseVisibleCreation(
        modelVisibleOutcomes.single,
      );
      createdPath = creation.relativePath;
      createdRevision = creation.revision;
      if (createdPath != _transientSourceRelativePath) {
        throw StateError('Create File returned another path.');
      }
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelToolProposalOutput(
          ProviderToolProposal(
            providerCallId: 'read-call-d1',
            alias: 'read_file',
            arguments: <String, Object?>{'relativePath': createdPath},
          ),
        ),
      );
    } else if (modelVisibleOutcomes.length == 2) {
      final _VisibleFile file = _parseVisibleFile(modelVisibleOutcomes.last);
      readPath = file.relativePath;
      readRevision = file.revision;
      observedContent = file.text;
      if (readPath != createdPath ||
          readRevision != createdRevision ||
          observedContent != _transientSourceContent) {
        throw StateError(
          'Read File did not observe the exact model-visible creation.',
        );
      }
      await beforeDelete();
      deleteExpectedRevision = file.revision;
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelToolProposalOutput(
          ProviderToolProposal(
            providerCallId: 'delete-call-d1',
            alias: 'delete_file',
            arguments: <String, Object?>{
              'relativePath': file.relativePath,
              'expectedRevision': file.revision,
            },
          ),
        ),
      );
    } else if (modelVisibleOutcomes.length == 3) {
      deleteResultConsumed =
          modelVisibleOutcomes.last ==
          'Deleted: ${jsonEncode(_transientSourceRelativePath)}';
      if (!deleteResultConsumed) {
        throw StateError('Delete File did not report the expected path.');
      }
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelTextOutput(
          'The transient file was created, verified, and deleted.',
        ),
      );
    } else {
      throw StateError('Unexpected deterministic model continuation.');
    }
    yield ModelInvocationSettledEvent(
      invocationId: request.invocationId,
      settlement: ModelSettlement.completed,
      metadata: ModelTerminalMetadata(
        effectiveModel: 'deterministic-create-read-delete-v1',
      ),
    );
  }
}

bool _isSuccessfulVisibleGitDiffCheck(String modelContent) =>
    modelContent.contains('Program: "git"\n') &&
    modelContent.contains('Arguments: ["diff","--check"]\n') &&
    modelContent.contains('Working directory: ""\n') &&
    modelContent.contains('Termination: exited\n') &&
    modelContent.contains('Exit code: 0\n') &&
    modelContent.contains('\nSTDOUT:\n') &&
    modelContent.contains('\nSTDERR:\n');

void _requireModelSchema(
  MaterializedTool tool, {
  required Set<String> expectedProperties,
}) {
  final Object? properties = tool.modelDefinition.argumentsSchema['properties'];
  if (properties is! Map<String, Object?> ||
      properties.keys.toSet().difference(expectedProperties).isNotEmpty ||
      properties.length != expectedProperties.length) {
    throw StateError(
      '${tool.modelDefinition.alias} exposed unexpected model arguments.',
    );
  }
}

final class _VisibleFile {
  const _VisibleFile({
    required this.relativePath,
    required this.revision,
    required this.text,
  });

  final String relativePath;
  final String revision;
  final String text;
}

_VisibleFile _parseVisibleFile(String modelContent) {
  final int firstNewline = modelContent.indexOf('\n');
  final int secondNewline = modelContent.indexOf('\n', firstNewline + 1);
  final int sourceSeparator = modelContent.indexOf('\n\n');
  if (firstNewline < 0 ||
      secondNewline < 0 ||
      sourceSeparator < secondNewline) {
    throw StateError('Read File returned malformed model-visible content.');
  }
  final String fileLine = modelContent.substring(0, firstNewline);
  final String revisionLine = modelContent.substring(
    firstNewline + 1,
    secondNewline,
  );
  const String filePrefix = 'File: ';
  const String revisionPrefix = 'Revision: ';
  if (!fileLine.startsWith(filePrefix) ||
      !revisionLine.startsWith(revisionPrefix)) {
    throw StateError('Read File omitted model-visible file metadata.');
  }
  final Object? relativePath = jsonDecode(
    fileLine.substring(filePrefix.length),
  );
  final Object? revision = jsonDecode(
    revisionLine.substring(revisionPrefix.length),
  );
  if (relativePath is! String || revision is! String) {
    throw StateError('Read File metadata was not encoded as strings.');
  }
  return _VisibleFile(
    relativePath: relativePath,
    revision: revision,
    text: modelContent.substring(sourceSeparator + 2),
  );
}

final class _VisiblePatch {
  const _VisiblePatch({
    required this.relativePath,
    required this.editCount,
    required this.revision,
  });

  final String relativePath;
  final int editCount;
  final String revision;
}

final class _VisibleCreation {
  const _VisibleCreation({required this.relativePath, required this.revision});

  final String relativePath;
  final String revision;
}

_VisibleCreation _parseVisibleCreation(String modelContent) {
  final int newline = modelContent.indexOf('\n');
  if (newline < 0) {
    throw StateError('Create File returned malformed model-visible content.');
  }
  final String pathLine = modelContent.substring(0, newline);
  final String revisionLine = modelContent.substring(newline + 1);
  const String pathPrefix = 'Created: ';
  const String revisionPrefix = 'Revision: ';
  if (!pathLine.startsWith(pathPrefix) ||
      !revisionLine.startsWith(revisionPrefix)) {
    throw StateError('Create File omitted model-visible file metadata.');
  }
  final Object? relativePath = jsonDecode(
    pathLine.substring(pathPrefix.length),
  );
  final Object? revision = jsonDecode(
    revisionLine.substring(revisionPrefix.length),
  );
  if (relativePath is! String || revision is! String) {
    throw StateError('Create File metadata was not encoded as strings.');
  }
  return _VisibleCreation(relativePath: relativePath, revision: revision);
}

_VisiblePatch _parseVisiblePatch(String modelContent) {
  final List<String> lines = modelContent.split('\n');
  if (lines.length != 3) {
    throw StateError('Apply Patch returned malformed model-visible content.');
  }
  final String pathLine = lines[0];
  final String editCountLine = lines[1];
  final String revisionLine = lines[2];
  const String pathPrefix = 'Patched: ';
  const String editCountPrefix = 'Edits applied: ';
  const String revisionPrefix = 'Revision: ';
  if (!pathLine.startsWith(pathPrefix) ||
      !editCountLine.startsWith(editCountPrefix) ||
      !revisionLine.startsWith(revisionPrefix)) {
    throw StateError('Apply Patch omitted model-visible file metadata.');
  }
  final Object? relativePath = jsonDecode(
    pathLine.substring(pathPrefix.length),
  );
  final Object? revision = jsonDecode(
    revisionLine.substring(revisionPrefix.length),
  );
  final int? editCount = int.tryParse(
    editCountLine.substring(editCountPrefix.length),
  );
  if (relativePath is! String || revision is! String) {
    throw StateError('Apply Patch metadata was not encoded as strings.');
  }
  if (editCount == null ||
      editCount < 1 ||
      editCountLine != '$editCountPrefix$editCount') {
    throw StateError('Apply Patch returned an invalid edit count.');
  }
  return _VisiblePatch(
    relativePath: relativePath,
    editCount: editCount,
    revision: revision,
  );
}

Future<ToolOutcome> _executeSearch(
  MaterializedTool tool,
  SessionId sessionId, {
  String path = 'plugins/chat_strategy/lib',
}) async {
  final CanonicalToolArguments arguments = tool.executable.validateAndNormalize(
    <String, Object?>{'query': 'final class ChatSessionState', 'path': path},
  );
  return (await tool.executable
              .execute(
                arguments,
                ToolExecutionContext(
                  runId: RunId('run-generation-search'),
                  sessionId: sessionId,
                ),
              )
              .single
          as ToolExecutionTerminal)
      .outcome;
}

Future<PluginCapabilityActivation> _startGeneration({
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

Future<String> _createSourceRepository({
  required String repository,
  required Directory source,
}) async {
  await source.create(recursive: true);
  final File maintainedSource = File('$repository/$_sourceRelativePath');
  final String content = await maintainedSource.readAsString();
  final File copiedSource = File('${source.path}/$_sourceRelativePath');
  await copiedSource.parent.create(recursive: true);
  await copiedSource.writeAsString(content);
  final List<String> supportingPaths = <String>[
    'README.md',
    'app/lib/development/agent/development_agent_support.dart',
  ];
  for (final String relativePath in supportingPaths) {
    final File maintained = File('$repository/$relativePath');
    final File copied = File('${source.path}/$relativePath');
    await copied.parent.create(recursive: true);
    await copied.writeAsString(await maintained.readAsString());
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
  return content;
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

final class _IntegrationIds implements ProductIdSource {
  const _IntegrationIds(this.sessionId);

  final String sessionId;

  @override
  EnvironmentId nextEnvironmentId() => EnvironmentId('environment-real-source');

  @override
  ProjectId nextProjectId() => ProjectId('project-real-source');

  @override
  SessionId nextSessionId() => SessionId(sessionId);

  @override
  TaskId nextTaskId() => TaskId('task-real-source');
}
