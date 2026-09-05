import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
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

const String _gitEnvironmentPluginId = 'dev.adele.plugin.git-environment';
const String _gitEnvironmentProviderId = 'dev.adele.environment.git-worktree';
const String _sourceRelativePath =
    'app/lib/development/agent/simple_tool_loop_strategy.dart';

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
      final ProductLifecycleCoordinator lifecycle =
          ProductLifecycleCoordinator.generated(
            store: store,
            registry: registry,
            ids: const _IntegrationIds(),
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
      final SessionId sessionId = SessionId('session-environment-read');
      final SessionEnvironmentAuthority authority = store.associateSession(
        sessionId: sessionId,
        taskId: created.task.id,
      );
      final ExtensionRegistry extensions = ExtensionRegistry();
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
      final DevelopmentSessionHistory history =
          DevelopmentSessionHistory(sessionId)..append(
            UserSessionMessage('Inspect the maintained ADELE strategy source.'),
          );
      final AgentRun run = AgentRun(
        id: RunId('run-environment-read'),
        sessionId: sessionId,
      );
      final _SearchReadModel model = _SearchReadModel();
      final DevelopmentToolLoopStrategy strategy = DevelopmentToolLoopStrategy(
        run: run,
        session: history,
        contextAssembler: const DevelopmentContextAssembler(
          instructions:
              'Search for and read the requested source before answering.',
        ),
        model: model,
        toolCatalog: catalogA,
        policy: const DevelopmentToolPolicy(ToolPolicyDecision.allow),
      );

      await strategy.start();

      expect(run.state, RunState.completed);
      expect(authority.environmentId, created.environment.id);
      expect(model.invocations, 3);
      expect(model.receivedRealSource, isTrue);
      expect(model.discoveredPath, _sourceRelativePath);
      expect(strategy.lastToolOutcome?.hostData['text'], expectedSource);
      expect(
        (history.snapshot().entries.last as AssistantSessionMessage).content,
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
        <String>['read_file', 'apply_patch'],
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
      final ToolOutcome restoredSearch = await _executeSearch(
        searchC,
        sessionId,
      );

      expect(materializationB, isNot(same(materializationA)));
      expect(materializationB.environment.id, materializationA.environment.id);
      expect(restoredSearch.disposition, ToolOutcomeDisposition.success);
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
    'agent reads then patches real source in its Session Environment',
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
      final ProductLifecycleCoordinator lifecycle =
          ProductLifecycleCoordinator.generated(
            store: store,
            registry: registry,
            ids: const _IntegrationIds(),
          );
      final Project project = lifecycle.createProject(source.uri);
      final TaskCreationResult created = await lifecycle.createTask(
        projectId: project.id,
        title: 'Patch real ADELE source',
        providerId: providerId,
      );
      final SessionId sessionId = SessionId('session-environment-patch');
      final SessionEnvironmentAuthority authority = store.associateSession(
        sessionId: sessionId,
        taskId: created.task.id,
      );
      final ExtensionRegistry extensions = ExtensionRegistry();
      final ExtensionRegistration filesystemActivation =
          const FilesystemToolsPlugin().activate(extensions);
      addTearDown(filesystemActivation.close);
      final ToolCatalog catalog = await buildModelToolCatalogForSession(
        sessionId: sessionId,
        environmentRuntime: lifecycle.environmentRuntime,
        extensions: extensions,
      );
      final MaterializedToolSet tools = catalog.materialize();
      final _ReadPatchModel model = _ReadPatchModel();
      final DevelopmentSessionHistory history = DevelopmentSessionHistory(
        sessionId,
      )..append(UserSessionMessage('Update the strategy default safely.'));
      final AgentRun run = AgentRun(
        id: RunId('run-environment-patch'),
        sessionId: sessionId,
      );
      final DevelopmentToolLoopStrategy strategy = DevelopmentToolLoopStrategy(
        run: run,
        session: history,
        contextAssembler: const DevelopmentContextAssembler(
          instructions:
              'Read the requested source, use its visible revision to patch '
              'one exact location, then report the result.',
        ),
        model: model,
        toolCatalog: catalog,
        policy: const DevelopmentToolPolicy(ToolPolicyDecision.allow),
      );

      expect(tools.tools.map((tool) => tool.modelDefinition.alias), <String>[
        'read_file',
        'apply_patch',
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
      expect(model.invocations, 3);
      expect(model.observedPath, _sourceRelativePath);
      expect(model.observedSource, originalSource);
      expect(model.expectedRevision, isNotEmpty);
      expect(model.postWriteRevision, isNot(model.expectedRevision));
      expect(authority.environmentId, created.environment.id);
      expect(
        (history.snapshot().entries.last as AssistantSessionMessage).content,
        contains('maxModelInvocations to 9'),
      );

      final List<ToolInvocationPrepared> prepared = run.journal.records
          .map((record) => record.event)
          .whereType<ToolInvocationPrepared>()
          .toList(growable: false);
      expect(
        prepared.map((event) => event.invocation.tool.modelDefinition.alias),
        <String>['read_file', 'apply_patch'],
      );
      expect(
        prepared.last.invocation.canonicalArguments['expectedRevision'],
        model.expectedRevision,
      );
      expect(
        prepared.last.invocation.canonicalArguments['search'],
        model.search,
      );
      final List<ToolExecutionCompleted> completed = run.journal.records
          .map((record) => record.event)
          .whereType<ToolExecutionCompleted>()
          .toList(growable: false);
      expect(completed, hasLength(2));
      expect(
        completed.map((event) => event.outcome.disposition),
        everyElement(ToolOutcomeDisposition.success),
      );
      expect(
        completed.map((event) => event.outcome.hostData['environmentId']),
        everyElement(authority.environmentId.value),
      );
      expect(
        completed.last.outcome.hostData['newRevision'],
        model.postWriteRevision,
      );
      final List<ToolPolicyEvaluated> policyEvaluations = run.journal.records
          .map((record) => record.event)
          .whereType<ToolPolicyEvaluated>()
          .toList(growable: false);
      expect(policyEvaluations, hasLength(2));
      expect(policyEvaluations.last.decision, ToolPolicyDecision.allow);
      expect(policyEvaluations.last.effects.effects, <ToolEffect>{
        ToolEffect.sourceMutation,
      });
      expect(
        policyEvaluations.last.effects.targets.single.uri.toString(),
        'adele-environment:/${authority.environmentId.value}/'
        '$_sourceRelativePath',
      );

      final EnvironmentMaterialization materialization = lifecycle
          .environmentRuntime
          .currentMaterialization(created.environment.id)!;
      final EnvironmentTextFile resultingFile = await materialization.provider
          .readFile(created.environment.id, _sourceRelativePath);
      expect(resultingFile.text, contains('this.maxModelInvocations = 9'));
      expect(
        resultingFile.text,
        isNot(contains('this.maxModelInvocations = 8')),
      );
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
      expect(unchangedProjectSource, contains('this.maxModelInvocations = 8'));
      expect(
        unchangedProjectSource,
        isNot(contains('this.maxModelInvocations = 9')),
      );

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
          }).isNotEmpty ||
          searchProperties.length != 1 ||
          readProperties is! Map<String, Object?> ||
          readProperties.keys.toSet().difference(<String>{
            'relativePath',
          }).isNotEmpty ||
          readProperties.length != 1) {
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
              'query': 'final class DevelopmentToolLoopStrategy',
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
          content.contains('final class DevelopmentToolLoopStrategy') &&
          content.contains('this.maxModelInvocations = 8');
      if (!receivedRealSource) {
        throw StateError(
          'The model did not receive real ADELE source content.',
        );
      }
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelTextOutput(
          '$discoveredPath declares DevelopmentToolLoopStrategy and defaults maxModelInvocations to 8.',
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

final class _ReadPatchModel implements ModelPort {
  int invocations = 0;
  String? observedPath;
  String? observedSource;
  String? expectedRevision;
  String? postWriteRevision;
  String? search;

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
        expectedProperties: const <String>{'relativePath'},
      );
      _requireModelSchema(
        applyPatch,
        expectedProperties: const <String>{
          'relativePath',
          'expectedRevision',
          'search',
          'replace',
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
          .where((line) => line.contains('this.maxModelInvocations = 8'))
          .toList(growable: false);
      if (candidateLines.length != 1) {
        throw StateError(
          'The model-visible source did not contain one patch target line.',
        );
      }
      search = candidateLines.single;
      final String replace = search!.replaceFirst(
        'this.maxModelInvocations = 8',
        'this.maxModelInvocations = 9',
      );
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelToolProposalOutput(
          ProviderToolProposal(
            providerCallId: 'patch-call-mutation',
            alias: 'apply_patch',
            arguments: <String, Object?>{
              'relativePath': file.relativePath,
              'expectedRevision': file.revision,
              'search': search,
              'replace': replace,
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
      postWriteRevision = result.revision;
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelTextOutput(
          'Patched $observedPath and changed maxModelInvocations to 9.',
        ),
      );
    } else {
      throw StateError('Unexpected deterministic model continuation.');
    }
    yield ModelInvocationSettledEvent(
      invocationId: request.invocationId,
      settlement: ModelSettlement.completed,
      metadata: ModelTerminalMetadata(
        effectiveModel: 'deterministic-read-patch-v1',
      ),
    );
  }
}

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
  if (firstNewline < 0 ||
      secondNewline < 0 ||
      secondNewline + 1 >= modelContent.length ||
      modelContent.codeUnitAt(secondNewline + 1) != 0x0a) {
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
    text: modelContent.substring(secondNewline + 2),
  );
}

final class _VisiblePatch {
  const _VisiblePatch({required this.relativePath, required this.revision});

  final String relativePath;
  final String revision;
}

_VisiblePatch _parseVisiblePatch(String modelContent) {
  final int newline = modelContent.indexOf('\n');
  if (newline < 0) {
    throw StateError('Apply Patch returned malformed model-visible content.');
  }
  final String pathLine = modelContent.substring(0, newline);
  final String revisionLine = modelContent.substring(newline + 1);
  const String pathPrefix = 'Patched: ';
  const String revisionPrefix = 'Revision: ';
  if (!pathLine.startsWith(pathPrefix) ||
      !revisionLine.startsWith(revisionPrefix)) {
    throw StateError('Apply Patch omitted model-visible file metadata.');
  }
  final Object? relativePath = jsonDecode(
    pathLine.substring(pathPrefix.length),
  );
  final Object? revision = jsonDecode(
    revisionLine.substring(revisionPrefix.length),
  );
  if (relativePath is! String || revision is! String) {
    throw StateError('Apply Patch metadata was not encoded as strings.');
  }
  return _VisiblePatch(relativePath: relativePath, revision: revision);
}

Future<ToolOutcome> _executeSearch(
  MaterializedTool tool,
  SessionId sessionId,
) async {
  final CanonicalToolArguments arguments = tool.executable.validateAndNormalize(
    const <String, Object?>{'query': 'final class DevelopmentToolLoopStrategy'},
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
  const _IntegrationIds();

  @override
  EnvironmentId nextEnvironmentId() => EnvironmentId('environment-real-source');

  @override
  ProjectId nextProjectId() => ProjectId('project-real-source');

  @override
  TaskId nextTaskId() => TaskId('task-real-source');
}
