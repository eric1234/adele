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
          'ADELE_PROCESS_SECRET_SHOULD_NOT_LEAK': 'sentinel',
          'OPENAI_API_KEY': 'sentinel',
          'PATH':
              'relative-bin:${Platform.environment['PATH'] ?? '/usr/bin:/bin'}',
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
      final EnvironmentTextFile firstRead = await providerA.readFile(
        durable.id,
        'README.md',
      );
      expect(firstRead.text, 'AOT Git fixture A\n');
      final EnvironmentTextFileCreation creation = await providerA
          .createTextFile(
            durable.id,
            'generated-create-delete.txt',
            'generated AOT content\n',
          );
      final EnvironmentTextFile createdRead = await providerA.readFile(
        durable.id,
        'generated-create-delete.txt',
      );
      expect(createdRead.text, 'generated AOT content\n');
      expect(createdRead.revision, creation.revision);
      await providerA.deleteExistingTextFile(
        durable.id,
        'generated-create-delete.txt',
        createdRead.revision,
      );
      await expectLater(
        providerA.readFile(durable.id, 'generated-create-delete.txt'),
        throwsA(_failureWithCode('not_found')),
      );
      final List<EnvironmentProcessEvent> processEvents = await providerA
          .runForegroundProcess(
            durable.id,
            EnvironmentForegroundProcessRequest(
              program: 'git',
              arguments: const <String>[
                'rev-parse',
                '--show-toplevel',
                '--show-prefix',
              ],
              relativeWorkingDirectory: '',
              timeoutSeconds: 10,
            ),
          )
          .toList();
      final List<String> processLines = _stdoutText(
        processEvents,
      ).trim().split('\n');
      expect(processLines, hasLength(2));
      expect(processLines.first, established.providerState['worktreePath']);
      expect(processLines.last, 'project-source/');
      expect(processEvents.last.kind, EnvironmentProcessEventKind.completed);
      expect(processEvents.last.completed!.exitCode, 0);
      expect(
        (await providerA.readFile(durable.id, 'README.md')).text,
        firstRead.text,
      );
      final List<EnvironmentProcessEvent> environmentEvents = await providerA
          .runForegroundProcess(
            durable.id,
            EnvironmentForegroundProcessRequest(
              program: 'env',
              arguments: const <String>[],
              relativeWorkingDirectory: '',
              timeoutSeconds: 10,
            ),
          )
          .toList();
      final List<String> childEnvironment = _stdoutText(
        environmentEvents,
      ).split('\n');
      expect(
        childEnvironment,
        isNot(contains('ADELE_PROCESS_SECRET_SHOULD_NOT_LEAK=sentinel')),
      );
      expect(childEnvironment, isNot(contains('OPENAI_API_KEY=sentinel')));
      expect(
        childEnvironment.any(
          (String variable) =>
              variable.startsWith('PATH=') && variable.length > 'PATH='.length,
        ),
        isTrue,
      );
      expect(
        childEnvironment,
        contains(
          'PATH=relative-bin:'
          '${Platform.environment['PATH'] ?? '/usr/bin:/bin'}',
        ),
      );
      expect(
        childEnvironment,
        contains(
          'PWD=${established.providerState['worktreePath']}'
          '${Platform.pathSeparator}project-source',
        ),
      );
      final List<EnvironmentProcessEvent> cleanStatus = await providerA
          .runForegroundProcess(
            durable.id,
            EnvironmentForegroundProcessRequest(
              program: 'git',
              arguments: const <String>['status', '--short'],
              relativeWorkingDirectory: '',
              timeoutSeconds: 10,
            ),
          )
          .toList();
      expect(_stdoutText(cleanStatus), isEmpty);
      expect(cleanStatus.last.completed!.exitCode, 0);
      final List<EnvironmentProcessEvent> relativePathProcess = await providerA
          .runForegroundProcess(
            durable.id,
            EnvironmentForegroundProcessRequest(
              program: 'adele-relative-path-probe',
              arguments: const <String>[],
              relativeWorkingDirectory: '',
              timeoutSeconds: 10,
            ),
          )
          .toList();
      expect(
        _stdoutText(relativePathProcess),
        'relative-path:${established.providerState['worktreePath']}'
        '${Platform.pathSeparator}project-source',
      );
      expect(relativePathProcess.last.completed!.exitCode, 0);
      final Stream<EnvironmentProcessEvent> deferredGenerationA = providerA
          .runForegroundProcess(
            durable.id,
            EnvironmentForegroundProcessRequest(
              program: 'git',
              arguments: const <String>['status', '--short'],
              relativeWorkingDirectory: '',
              timeoutSeconds: 10,
            ),
          );
      final EnvironmentTextFileReplacement replacement = await providerA
          .replaceExistingTextFile(
            durable.id,
            'README.md',
            'AOT conditional replacement\n',
            firstRead.revision,
          );
      final EnvironmentTextFile replacedRead = await providerA.readFile(
        durable.id,
        'README.md',
      );
      expect(replacedRead.text, 'AOT conditional replacement\n');
      expect(replacedRead.revision, replacement.revision);
      expect(replacedRead.revision, isNot(firstRead.revision));
      await expectLater(
        providerA.replaceExistingTextFile(
          durable.id,
          'README.md',
          'stale replacement\n',
          firstRead.revision,
        ),
        throwsA(_failureWithCode('revision_conflict')),
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
      await expectLater(
        deferredGenerationA,
        emitsError(isA<PluginConnectionClosed>()),
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
        'AOT conditional replacement\n',
      );
      expect(refreshed.providerState, durable.providerState);
      final List<EnvironmentProcessEvent> freshProcess = await providerB
          .runForegroundProcess(
            refreshed.id,
            EnvironmentForegroundProcessRequest(
              program: 'git',
              arguments: const <String>['status', '--short'],
              relativeWorkingDirectory: '',
              timeoutSeconds: 10,
            ),
          )
          .toList();
      expect(freshProcess.last.completed!.exitCode, 0);
      expect(_stdoutText(freshProcess), contains('M README.md'));

      await activationB.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

String _stdoutText(List<EnvironmentProcessEvent> events) => events
    .where(
      (EnvironmentProcessEvent event) =>
          event.output?.stream == EnvironmentProcessOutputStream.stdout,
    )
    .map((EnvironmentProcessEvent event) => event.output!.text)
    .join();

Matcher _failureWithCode(String code) => isA<EnvironmentFailure>().having(
  (EnvironmentFailure failure) => failure.code,
  'code',
  code,
);

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
  final Directory relativeBin = Directory(
    '${projectSourceA.path}${Platform.pathSeparator}relative-bin',
  );
  await relativeBin.create();
  final File relativePathProbe = File(
    '${relativeBin.path}${Platform.pathSeparator}adele-relative-path-probe',
  );
  await relativePathProbe.writeAsString(
    '#!/bin/sh\nprintf "relative-path:%s" "\$PWD"\n',
  );
  final ProcessResult chmod = await Process.run('chmod', <String>[
    '755',
    relativePathProbe.path,
  ]);
  if (chmod.exitCode != 0) throw StateError(chmod.stderr.toString());
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
