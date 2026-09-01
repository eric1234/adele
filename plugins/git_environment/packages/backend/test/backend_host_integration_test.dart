import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:git_environment_backend/git_environment_backend.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

void main() {
  late String repository;
  late String dartaotruntime;
  late File hostArtifact;
  late File pluginArtifact;

  setUpAll(() async {
    repository = Directory.current.parent.parent.parent.parent.path;
    final Directory artifacts = Directory(
      '$repository/.dart_tool/adele/integration/git-environment',
    )..createSync(recursive: true);
    final String dart = Platform.resolvedExecutable;
    dartaotruntime = '${File(dart).parent.path}/dartaotruntime';
    hostArtifact = File('${artifacts.path}/host.aot');
    pluginArtifact = File('${artifacts.path}/git-environment.aot');
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
        pluginArtifact.path,
        repository,
      ),
    ]);
  });

  test(
    'AOT generations ignore inherited Git routing/discovery and restore state',
    () async {
      final ({
        Directory container,
        Directory projectSourceA,
        Directory sourceA,
        Directory sourceB,
      })
      fixture = await _createRepository();
      addTearDown(() => fixture.container.delete(recursive: true));
      final String gitDirVariable = Platform.isWindows ? 'git_dir' : 'GIT_DIR';
      final String ceilingVariable = Platform.isWindows
          ? 'Git_Ceiling_Directories'
          : 'GIT_CEILING_DIRECTORIES';
      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
        environment: <String, String>{
          gitDirVariable:
              '${fixture.sourceB.path}${Platform.pathSeparator}.git',
          'GIT_WORK_TREE': fixture.sourceB.path,
          ceilingVariable: fixture.sourceA.path,
          'GIT_DISCOVERY_ACROSS_FILESYSTEM': 'false',
        },
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final CapabilityRegistry registry = CapabilityRegistry();
      final ProviderId providerId = ProviderId(
        gitWorktreeEnvironmentProviderId,
      );
      final Project project = Project(
        id: ProjectId('project-aot'),
        sourceLocation: fixture.projectSourceA.uri,
      );
      final Task task = Task(
        id: TaskId('task-aot'),
        projectId: project.id,
        title: 'AOT Generation Proof',
      );
      final Environment provisional = Environment(
        id: EnvironmentId('environment-aot'),
        taskId: task.id,
        role: EnvironmentRole.primary,
        providerId: providerId,
        providerState: null,
      );

      final PluginBackendConnection generationA = await host.startPlugin(
        pluginId: gitEnvironmentPluginId,
        artifactUri: pluginArtifact.uri,
      );
      final PluginCapabilityActivation activationA = await _register(
        generationA,
        registry,
      );
      final ProviderBinding bindingA = registry.resolve(
        environmentProviderCapability,
        providerId: providerId,
      );
      final GeneratedEnvironmentProvider providerA =
          GeneratedEnvironmentProvider(
            providerId: providerId,
            service: EnvironmentProviderServiceClient(bindingA.requestChannel),
          );
      final EnvironmentProviderResult established = await providerA.establish(
        LocalEnvironment(project: project, task: task, value: provisional),
      );
      final Environment durable = Environment(
        id: provisional.id,
        taskId: provisional.taskId,
        role: provisional.role,
        providerId: provisional.providerId,
        providerState: established.providerState,
      );
      expect(
        established.providerState['baselineCommit'],
        await _git(fixture.sourceA, <String>['rev-parse', 'HEAD']),
      );
      expect(
        established.providerState['baselineCommit'],
        isNot(await _git(fixture.sourceB, <String>['rev-parse', 'HEAD'])),
      );
      expect(
        (await providerA.readFile(durable.id, 'README.md')).text,
        'AOT Git fixture A\n',
      );

      await activationA.close();
      final PluginBackendConnection generationB = await host.startPlugin(
        pluginId: gitEnvironmentPluginId,
        artifactUri: pluginArtifact.uri,
      );
      final PluginCapabilityActivation activationB = await _register(
        generationB,
        registry,
      );
      expect(
        () => bindingA.requestChannel,
        throwsA(
          isA<ProviderUnavailable>()
              .having(
                (ProviderUnavailable failure) => failure.stale,
                'stale',
                isTrue,
              )
              .having(
                (ProviderUnavailable failure) => failure.providerId,
                'providerId',
                providerId,
              ),
        ),
      );
      await expectLater(
        providerA.readFile(durable.id, 'README.md'),
        throwsA(isA<PluginConnectionClosed>()),
      );

      expect(durable.providerId, providerId);
      expect(durable.providerState, established.providerState);
      final ProviderBinding bindingB = registry.resolve(
        environmentProviderCapability,
        providerId: providerId,
      );
      final GeneratedEnvironmentProvider providerB =
          GeneratedEnvironmentProvider(
            providerId: providerId,
            service: EnvironmentProviderServiceClient(bindingB.requestChannel),
          );
      final EnvironmentProviderResult restored = await providerB.restore(
        LocalEnvironment(project: project, task: task, value: durable),
      );
      final Environment refreshed = Environment(
        id: durable.id,
        taskId: durable.taskId,
        role: durable.role,
        providerId: durable.providerId,
        providerState: restored.providerState,
      );
      expect(
        (await providerB.readFile(refreshed.id, 'README.md')).text,
        'AOT Git fixture A\n',
      );
      expect(refreshed.providerState, durable.providerState);

      await activationB.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Future<PluginCapabilityActivation> _register(
  PluginBackendConnection connection,
  CapabilityRegistry registry,
) => PluginCapabilityActivation.register(
  connection: connection,
  registry: registry,
  exposures: <PluginCapabilityExposure>[
    PluginCapabilityExposure(
      provider: ProviderDescriptor(
        id: ProviderId(gitWorktreeEnvironmentProviderId),
        capability: environmentProviderCapability,
        pluginId: connection.pluginId,
        displayName: 'Git Worktree Environment',
        serviceId: environmentProviderServiceId,
      ),
      configurationContext: connection.defaultConfigurationContext,
    ),
  ],
);

Future<
  ({
    Directory container,
    Directory projectSourceA,
    Directory sourceA,
    Directory sourceB,
  })
>
_createRepository() async {
  final Directory container = await Directory.systemTemp.createTemp(
    'adele-git-environment-aot-',
  );
  final Directory sourceA = Directory('${container.path}/source-a');
  final Directory sourceB = Directory('${container.path}/source-b');
  await _initializeRepository(sourceA, 'AOT Git fixture A\n');
  await _initializeRepository(sourceB, 'AOT Git fixture B\n');
  final Directory projectSourceA = Directory(
    '${sourceA.path}${Platform.pathSeparator}project-source',
  );
  await projectSourceA.create();
  await File(
    '${projectSourceA.path}${Platform.pathSeparator}README.md',
  ).writeAsString('AOT Git fixture A\n');
  await _git(sourceA, <String>['add', '.']);
  await _git(sourceA, <String>['commit', '-m', 'Add nested Project source']);
  return (
    container: container,
    projectSourceA: projectSourceA,
    sourceA: sourceA,
    sourceB: sourceB,
  );
}

Future<void> _initializeRepository(Directory source, String marker) async {
  await source.create();
  await _git(source, <String>['init']);
  await _git(source, <String>['config', 'user.name', 'ADELE Test']);
  await _git(source, <String>['config', 'user.email', 'adele@example.invalid']);
  await File('${source.path}/README.md').writeAsString(marker);
  await _git(source, <String>['add', '.']);
  await _git(source, <String>['commit', '-m', 'Initial fixture']);
}

Future<String> _git(Directory source, List<String> arguments) async {
  final ProcessResult result = await Process.run('git', <String>[
    '-C',
    source.path,
    ...arguments,
  ]);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return result.stdout.toString().trim();
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
