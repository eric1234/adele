import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/development/agent/agent_capability_adapters.dart';
import 'package:adele_desktop/development/agent/development_self_hosting.dart';
import 'package:adele_desktop/development/agent/development_self_hosting_report.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:crypto/crypto.dart';

const List<String> developmentSelfHostingPhases = <String>[
  'sourceReconciliationPreflight',
  'artifactCompilation',
  'projectClone',
  'lifecycleTaskEnvironmentSetup',
  'providerActivation',
  'adeleRun',
  'evidenceReportGeneration',
  'teardown',
];

final class DevelopmentSelfHostingUsageException implements Exception {
  const DevelopmentSelfHostingUsageException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class DevelopmentSelfHostingOptions {
  const DevelopmentSelfHostingOptions({
    required this.promptFile,
    required this.instructionsFile,
    required this.taskTitle,
    required this.maxModelInvocations,
    required this.outputRoot,
    required this.profile,
  });

  final File promptFile;
  final File instructionsFile;
  final String taskTitle;
  final int maxModelInvocations;
  final Directory outputRoot;
  final DevelopmentSelfHostingProfile profile;

  static DevelopmentSelfHostingOptions parse(List<String> arguments) {
    final Map<String, String> values = <String, String>{};
    for (var index = 0; index < arguments.length; index++) {
      final String argument = arguments[index];
      if (!argument.startsWith('--')) {
        throw DevelopmentSelfHostingUsageException(
          'Unexpected positional argument: $argument',
        );
      }
      final int equals = argument.indexOf('=');
      final String name = equals < 0 ? argument : argument.substring(0, equals);
      if (values.containsKey(name)) {
        throw DevelopmentSelfHostingUsageException(
          '$name may only be specified once.',
        );
      }
      final String value;
      if (equals >= 0) {
        value = argument.substring(equals + 1);
      } else {
        if (index + 1 >= arguments.length ||
            arguments[index + 1].startsWith('--')) {
          throw DevelopmentSelfHostingUsageException('$name requires a value.');
        }
        value = arguments[++index];
      }
      if (value.isEmpty) {
        throw DevelopmentSelfHostingUsageException(
          '$name requires a non-empty value.',
        );
      }
      values[name] = value;
    }
    const Set<String> supported = <String>{
      '--prompt-file',
      '--instructions-file',
      '--task-title',
      '--max-model-invocations',
      '--output-dir',
      '--profile',
    };
    final List<String> unknown = values.keys
        .where((String name) => !supported.contains(name))
        .toList(growable: false);
    if (unknown.isNotEmpty) {
      throw DevelopmentSelfHostingUsageException(
        'Unknown option: ${unknown.first}',
      );
    }
    String required(String name) {
      final String? value = values[name];
      if (value == null) {
        throw DevelopmentSelfHostingUsageException('$name is required.');
      }
      return value;
    }

    final String maximumValue = required('--max-model-invocations');
    final int? maximum = RegExp(r'^[1-9][0-9]*$').hasMatch(maximumValue)
        ? int.tryParse(maximumValue)
        : null;
    if (maximum == null) {
      throw const DevelopmentSelfHostingUsageException(
        '--max-model-invocations requires a positive integer.',
      );
    }
    final String profileValue = values['--profile'] ?? 'chatgpt';
    final DevelopmentSelfHostingProfile profile = switch (profileValue) {
      'chatgpt' => DevelopmentSelfHostingProfile.chatgpt,
      'api-key' => DevelopmentSelfHostingProfile.apiKey,
      _ => throw DevelopmentSelfHostingUsageException(
        'Unknown --profile value "$profileValue"; expected chatgpt or api-key.',
      ),
    };
    return DevelopmentSelfHostingOptions(
      promptFile: File(required('--prompt-file')).absolute,
      instructionsFile: File(required('--instructions-file')).absolute,
      taskTitle: required('--task-title'),
      maxModelInvocations: maximum,
      outputRoot: Directory(required('--output-dir')).absolute,
      profile: profile,
    );
  }
}

final class DevelopmentSelfHostingRunnerResult {
  const DevelopmentSelfHostingRunnerResult({
    required this.exitCode,
    required this.runDirectory,
    required this.projectSource,
    required this.taskWorktree,
    required this.runState,
    required this.failure,
  });

  final int exitCode;
  final Directory runDirectory;
  final Directory? projectSource;
  final Directory? taskWorktree;
  final RunState? runState;
  final Object? failure;
}

final class DevelopmentSelfHostingRunner {
  const DevelopmentSelfHostingRunner();

  Future<DevelopmentSelfHostingRunnerResult> run(
    DevelopmentSelfHostingOptions options,
  ) async {
    final DateTime startedAt = DateTime.now().toUtc();
    final _PhaseTimings timings = _PhaseTimings();
    Directory launchingRepository = Directory.current.absolute;
    String? sourceHead;
    String? promptHash;
    String? instructionsHash;
    String? prompt;
    String? instructions;
    DevelopmentSelfHostingProviderConfiguration? providerConfiguration;
    Object? failure;
    DevelopmentSelfHostingArtifacts? artifacts;
    DevelopmentSelfHostingTopology? topology;
    DevelopmentSelfHostingRetainedState? retainedState;
    DevelopmentSelfHostingProviderActivation? providerActivation;
    DevelopmentSelfHostingRunResult? runResult;
    late final Directory runDirectory;
    late final _RunnerLogger logger;

    try {
      await timings.measure('sourceReconciliationPreflight', () async {
        launchingRepository = await _discoverRepository();
        sourceHead = await _gitValue(launchingRepository, const <String>[
          'rev-parse',
          'HEAD',
        ]);
        final String status = await _gitValue(
          launchingRepository,
          const <String>['status', '--porcelain', '--untracked-files=all'],
        );
        if (status.trim().isNotEmpty) {
          throw StateError(
            'Developer self-hosting requires a clean launching checkout.',
          );
        }
        final List<int> promptBytes = await options.promptFile.readAsBytes();
        final List<int> instructionBytes = await options.instructionsFile
            .readAsBytes();
        prompt = utf8.decode(promptBytes);
        instructions = utf8.decode(instructionBytes);
        if (prompt!.trim().isEmpty) {
          throw StateError('The prompt file must not be empty.');
        }
        if (instructions!.trim().isEmpty) {
          throw StateError('The instructions file must not be empty.');
        }
        promptHash = sha256.convert(promptBytes).toString();
        instructionsHash = sha256.convert(instructionBytes).toString();
        providerConfiguration =
            DevelopmentSelfHostingProviderConfiguration.fromEnvironment(
              options.profile,
            );
      });
    } on Object catch (error) {
      failure = error;
    }

    runDirectory = await _createRunDirectory(
      options.outputRoot,
      startedAt,
      sourceHead,
    );
    logger = await _RunnerLogger.open(runDirectory);
    logger.log('ADELE developer self-hosting runner started.');
    logger.log('Run directory: ${runDirectory.path}');
    logger.log('Launching checkout: ${launchingRepository.path}');
    if (sourceHead != null) logger.log('Starting source SHA: $sourceHead');
    if (failure != null) logger.log('Preflight failed: $failure');

    final String identity = _identity(startedAt, sourceHead);
    final Directory transientArtifacts = Directory(
      '${runDirectory.path}/.artifacts',
    );
    final Directory projectSource = Directory(
      '${runDirectory.path}/state/project',
    );
    try {
      if (failure == null) {
        artifacts = await timings.measure('artifactCompilation', () async {
          final DevelopmentSelfHostingArtifacts compiled =
              await DevelopmentSelfHostingArtifacts.compile(
                repository: launchingRepository,
                outputDirectory: transientArtifacts,
                log: logger.log,
              );
          await _requireSourceBaseline(
            launchingRepository,
            sourceHead!,
            runDirectory,
          );
          return compiled;
        });
        await timings.measure('projectClone', () async {
          await Directory('${runDirectory.path}/state').create(recursive: true);
          await cloneDevelopmentSelfHostingProject(
            repository: launchingRepository,
            destination: projectSource,
            sourceHead: sourceHead!,
            log: logger.log,
          );
        });
        topology = await timings.measure(
          'lifecycleTaskEnvironmentSetup',
          () => DevelopmentSelfHostingTopology.start(
            artifacts: artifacts!,
            projectSource: projectSource,
            hostEnvironment: providerConfiguration!.hostEnvironment,
            identity: identity,
            taskTitle: options.taskTitle,
            log: logger.log,
            onTaskEstablished: (DevelopmentSelfHostingRetainedState state) {
              retainedState = state;
              logger.log('Project source: ${state.projectSource.path}');
              logger.log('Task worktree: ${state.taskWorktreePath}');
            },
          ),
        );
        final DevelopmentSelfHostingTopology activeTopology = topology!;
        final DevelopmentSelfHostingArtifacts activeArtifacts = artifacts!;
        final DevelopmentSelfHostingProviderConfiguration activeConfiguration =
            providerConfiguration!;
        providerActivation = await timings.measure(
          'providerActivation',
          () => activateDevelopmentSelfHostingModelProvider(
            host: activeTopology.host,
            registry: activeTopology.registry,
            artifact: activeArtifacts.openAiArtifact,
            profile: options.profile,
          ),
        );
        final ModelProviderCapabilityAdapter model =
            ModelProviderCapabilityAdapter(
              activeTopology.registry.resolve(
                modelProviderCapability,
                providerId: ProviderId(options.profile.providerId),
              ),
              selectedModel: activeConfiguration.selectedModel,
            );
        final List<String> aliases = activeTopology.catalog
            .materialize()
            .tools
            .map((MaterializedTool tool) => tool.modelDefinition.alias)
            .toList(growable: false);
        if (!_sameStrings(aliases, developmentSelfHostingToolAliases)) {
          throw StateError('Unexpected developer tool catalog: $aliases');
        }
        logger.log('Model profile: ${options.profile.cliName}.');
        logger.log('Selected model: ${activeConfiguration.selectedModel}.');
        logger.log('Model invocation ceiling: ${options.maxModelInvocations}.');
        final DevelopmentSelfHostingRunResult completedRun = await timings
            .measure(
              'adeleRun',
              () => executeDevelopmentSelfHostingRun(
                identity: identity,
                sessionId: activeTopology.sessionId,
                prompt: prompt!,
                instructions: instructions!,
                model: model,
                catalog: activeTopology.catalog,
                maxModelInvocations: options.maxModelInvocations,
              ),
            );
        runResult = completedRun;
        logger.log('ADELE Run state: ${completedRun.run.state.name}.');
        if (!completedRun.succeeded) {
          failure =
              completedRun.run.failure ??
              completedRun.executionFailure ??
              StateError('The ADELE Run did not complete successfully.');
        }
      }
    } on Object catch (error) {
      failure ??= error;
      logger.log('Runner failure: $error');
    } finally {
      try {
        await timings.measure('teardown', () async {
          await closeDevelopmentSelfHostingResources(<Future<void> Function()>[
            if (providerActivation != null) providerActivation.close,
            if (topology != null) topology.close,
            if (await transientArtifacts.exists())
              () => transientArtifacts.delete(recursive: true),
          ]);
        });
      } on Object catch (error) {
        failure ??= error;
        logger.log('Teardown failure: $error');
      }
    }

    DevelopmentSelfHostingGitEvidence git;
    final Stopwatch evidenceCollection = Stopwatch()..start();
    git = await collectDevelopmentSelfHostingGitEvidence(
      launchingRepository: launchingRepository,
      projectSource: await projectSource.exists() ? projectSource : null,
      taskWorktree: retainedState == null
          ? null
          : Directory(retainedState!.taskWorktreePath),
      taskBaseline: retainedState?.baselineCommit,
    );
    evidenceCollection.stop();
    timings.set(
      'evidenceReportGeneration',
      evidenceCollection.elapsedMilliseconds,
    );
    final DevelopmentSelfHostingEvidenceContext evidenceContext =
        DevelopmentSelfHostingEvidenceContext(
          runDirectory: runDirectory,
          launchingRepository: launchingRepository,
          sourceHead: sourceHead,
          projectSource: await projectSource.exists() ? projectSource : null,
          taskWorktree: retainedState == null
              ? null
              : Directory(retainedState!.taskWorktreePath),
          taskTitle: options.taskTitle,
          taskBranch: retainedState?.taskBranch,
          taskBaseline: retainedState?.baselineCommit,
          projectId: retainedState?.projectId.value,
          taskId: retainedState?.taskId.value,
          environmentId: retainedState?.environmentId.value,
          sessionId: topology?.sessionId.value,
          profile: options.profile.cliName,
          providerId: options.profile.providerId,
          configuredContext: options.profile.configuredContext,
          selectedModel: providerConfiguration?.selectedModel,
          maxModelInvocations: options.maxModelInvocations,
          promptFileHash: promptHash,
          instructionsFileHash: instructionsHash,
          startedAt: startedAt,
          phaseDurations: timings.values,
          runnerFailure: failure,
        );
    try {
      await const DevelopmentSelfHostingEvidenceWriter().write(
        context: evidenceContext,
        result: runResult,
        git: git,
      );
      logger.log('Evidence written to ${runDirectory.path}.');
    } on Object catch (error) {
      failure ??= error;
      logger.log('Evidence generation failed: $error');
    }
    final Directory? retainedProject = await projectSource.exists()
        ? projectSource
        : null;
    final Directory? retainedTask = retainedState == null
        ? null
        : Directory(retainedState!.taskWorktreePath);
    logger.log('Project source: ${retainedProject?.path ?? 'unavailable'}');
    logger.log('Task worktree: ${retainedTask?.path ?? 'unavailable'}');
    logger.log('Runner exit status: ${failure == null ? 0 : 1}.');
    await logger.close();
    return DevelopmentSelfHostingRunnerResult(
      exitCode: failure == null ? 0 : 1,
      runDirectory: runDirectory,
      projectSource: retainedProject,
      taskWorktree: retainedTask,
      runState: runResult?.run.state,
      failure: failure,
    );
  }
}

Future<Directory> _discoverRepository() async {
  final ProcessResult result = await Process.run(
    'git',
    const <String>['rev-parse', '--show-toplevel'],
    workingDirectory: Directory.current.path,
    runInShell: Platform.isWindows,
  );
  if (result.exitCode != 0) {
    throw StateError('The runner must be launched from an ADELE Git checkout.');
  }
  return Directory(result.stdout.toString().trim()).absolute;
}

Future<String> _gitValue(Directory repository, List<String> arguments) async {
  final ProcessResult result = await Process.run(
    'git',
    arguments,
    workingDirectory: repository.path,
    runInShell: Platform.isWindows,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'git ${arguments.join(' ')} failed: ${result.stderr.toString().trim()}',
    );
  }
  return result.stdout.toString().trim();
}

Future<void> _requireSourceBaseline(
  Directory repository,
  String expectedHead,
  Directory runDirectory,
) async {
  final String currentHead = await _gitValue(repository, const <String>[
    'rev-parse',
    'HEAD',
  ]);
  if (currentHead != expectedHead) {
    throw StateError(
      'The launching checkout HEAD changed during artifact compilation.',
    );
  }
  final String status = await _gitValue(repository, const <String>[
    'status',
    '--porcelain',
    '--untracked-files=all',
  ]);
  final String repositoryPrefix = '${repository.path}${Platform.pathSeparator}';
  final String? runRelative = runDirectory.path.startsWith(repositoryPrefix)
      ? runDirectory.path
            .substring(repositoryPrefix.length)
            .replaceAll(Platform.pathSeparator, '/')
      : null;
  final List<String> unexpected = const LineSplitter()
      .convert(status)
      .where((String line) {
        if (runRelative == null || line.length < 4) return true;
        final String path = line.substring(3);
        return path != runRelative && !path.startsWith('$runRelative/');
      })
      .toList(growable: false);
  if (unexpected.isNotEmpty) {
    throw StateError(
      'The launching checkout changed during artifact compilation.',
    );
  }
}

Future<Directory> _createRunDirectory(
  Directory outputRoot,
  DateTime startedAt,
  String? sourceHead,
) async {
  await outputRoot.create(recursive: true);
  final String timestamp = startedAt.toUtc().toIso8601String().replaceAll(
    RegExp(r'[-:.]'),
    '',
  );
  final String revision = sourceHead == null
      ? 'unknown'
      : sourceHead.substring(
          0,
          sourceHead.length < 12 ? sourceHead.length : 12,
        );
  final String base = 'run-$timestamp-$revision';
  var suffix = 1;
  while (true) {
    final Directory candidate = Directory(
      '${outputRoot.path}/$base${suffix == 1 ? '' : '-$suffix'}',
    );
    if (await candidate.exists()) {
      suffix++;
      continue;
    }
    try {
      await candidate.create();
      return candidate;
    } on FileSystemException {
      if (!await candidate.exists()) rethrow;
      suffix++;
    }
  }
}

String _identity(DateTime startedAt, String? sourceHead) {
  final String micros = startedAt.microsecondsSinceEpoch.toString();
  final String revision = sourceHead == null
      ? 'unknown'
      : sourceHead.substring(0, sourceHead.length < 8 ? sourceHead.length : 8);
  return '$micros-$revision';
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

final class _PhaseTimings {
  _PhaseTimings()
    : _values = <String, int?>{
        for (final String phase in developmentSelfHostingPhases) phase: null,
      };

  final Map<String, int?> _values;

  Map<String, int?> get values => Map<String, int?>.unmodifiable(_values);

  Future<T> measure<T>(String phase, Future<T> Function() operation) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    try {
      return await operation();
    } finally {
      stopwatch.stop();
      _values[phase] = stopwatch.elapsedMilliseconds;
    }
  }

  void set(String phase, int milliseconds) => _values[phase] = milliseconds;
}

final class _RunnerLogger {
  _RunnerLogger._(this._sink);

  final IOSink _sink;

  static Future<_RunnerLogger> open(Directory runDirectory) async {
    final File file = File('${runDirectory.path}/runner.log');
    return _RunnerLogger._(file.openWrite());
  }

  void log(String message) {
    final String line =
        '[${DateTime.now().toUtc().toIso8601String()}] $message';
    stdout.writeln(line);
    _sink.writeln(line);
  }

  Future<void> close() => _sink.close();
}
