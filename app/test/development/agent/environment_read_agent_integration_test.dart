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
      '$repository/.dart_tool/adele/integration/phase-v-a2-environment-read',
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
    'agent reads real ADELE source through Session Environment generations',
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
      final ExtensionRegistration filesystemGenerationA =
          const FilesystemToolsPlugin().activate(extensions);
      final ToolCatalog catalogA = await buildModelToolCatalogForSession(
        sessionId: sessionId,
        environmentRuntime: lifecycle.environmentRuntime,
        extensions: extensions,
      );
      final MaterializedTool readFileA = catalogA.materialize().byAlias(
        'read_file',
      )!;
      final DevelopmentSessionHistory history =
          DevelopmentSessionHistory(sessionId)..append(
            UserSessionMessage('Inspect the maintained ADELE strategy source.'),
          );
      final AgentRun run = AgentRun(
        id: RunId('run-environment-read'),
        sessionId: sessionId,
      );
      final _ReadFileModel model = _ReadFileModel(_sourceRelativePath);
      final DevelopmentToolLoopStrategy strategy = DevelopmentToolLoopStrategy(
        run: run,
        session: history,
        contextAssembler: const DevelopmentContextAssembler(
          instructions: 'Read the requested source before answering.',
        ),
        model: model,
        toolCatalog: catalogA,
        policy: const DevelopmentToolPolicy(ToolPolicyDecision.allow),
      );

      await strategy.start();

      expect(run.state, RunState.completed);
      expect(authority.environmentId, created.environment.id);
      expect(model.invocations, 2);
      expect(model.receivedRealSource, isTrue);
      expect(strategy.lastToolOutcome?.hostData['text'], expectedSource);
      expect(
        (history.snapshot().entries.last as AssistantSessionMessage).content,
        contains('DevelopmentToolLoopStrategy'),
      );

      await filesystemGenerationA.close();
      expect(
        readFileA.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      final ToolCatalog inactiveCatalog = await buildModelToolCatalogForSession(
        sessionId: sessionId,
        environmentRuntime: lifecycle.environmentRuntime,
        extensions: extensions,
      );
      expect(inactiveCatalog.materialize().tools, isEmpty);

      final ExtensionRegistration filesystemGenerationB =
          const FilesystemToolsPlugin().activate(extensions);
      addTearDown(filesystemGenerationB.close);
      final ToolCatalog pluginGenerationBCatalog =
          await buildModelToolCatalogForSession(
            sessionId: sessionId,
            environmentRuntime: lifecycle.environmentRuntime,
            extensions: extensions,
          );
      final MaterializedTool pluginGenerationBTool = pluginGenerationBCatalog
          .materialize()
          .byAlias('read_file')!;
      expect(pluginGenerationBTool.executable.validateBinding, returnsNormally);
      expect(
        readFileA.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );

      await environmentGenerationA.close();
      expect(
        pluginGenerationBTool.executable.validateBinding,
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
      final CanonicalToolArguments arguments = readFileB.executable
          .validateAndNormalize(const <String, Object?>{
            'relativePath': _sourceRelativePath,
          });
      final ToolOutcome restoredOutcome =
          (await readFileB.executable
                      .execute(
                        arguments,
                        ToolExecutionContext(
                          runId: RunId('run-restored-read'),
                          sessionId: sessionId,
                        ),
                      )
                      .single
                  as ToolExecutionTerminal)
              .outcome;

      expect(materializationB, isNot(same(materializationA)));
      expect(materializationB.environment.id, materializationA.environment.id);
      expect(restoredOutcome.disposition, ToolOutcomeDisposition.success);
      expect(restoredOutcome.hostData['text'], expectedSource);
      expect(
        readFileA.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );

      await environmentGenerationB.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

final class _ReadFileModel implements ModelPort {
  _ReadFileModel(this.relativePath);

  final String relativePath;
  int invocations = 0;
  bool receivedRealSource = false;

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    invocations++;
    final List<SemanticToolOutcomeInput> outcomes = request.input
        .whereType<SemanticToolOutcomeInput>()
        .toList(growable: false);
    if (outcomes.isEmpty) {
      final MaterializedTool tool = request.tools.byAlias('read_file')!;
      final Object? properties =
          tool.modelDefinition.argumentsSchema['properties'];
      if (properties is! Map<String, Object?> ||
          properties.length != 1 ||
          !properties.containsKey('relativePath')) {
        throw StateError(
          'read_file exposed Environment selection to the model.',
        );
      }
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelToolProposalOutput(
          ProviderToolProposal(
            providerCallId: 'read-call-1',
            alias: 'read_file',
            arguments: <String, Object?>{'relativePath': relativePath},
          ),
        ),
      );
    } else {
      final String content = outcomes.single.outcome.modelContent;
      receivedRealSource = content.contains(
        'final class DevelopmentToolLoopStrategy',
      );
      if (!receivedRealSource) {
        throw StateError(
          'The model did not receive real ADELE source content.',
        );
      }
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelTextOutput(
          'The Environment contains DevelopmentToolLoopStrategy.',
        ),
      );
    }
    yield ModelInvocationSettledEvent(
      invocationId: request.invocationId,
      settlement: ModelSettlement.completed,
      metadata: ModelTerminalMetadata(effectiveModel: 'deterministic-read-v1'),
    );
  }
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
