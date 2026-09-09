import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:adele_desktop/development/agent/development_self_hosting.dart';
import 'package:adele_desktop/development/agent/simple_tool_loop_strategy.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:agent_kernel/agent_kernel.dart';

const int developmentSelfHostingReportSchemaVersion = 1;

const List<String> developmentSelfHostingToolAliases = <String>[
  'read_file',
  'apply_patch',
  'create_file',
  'delete_file',
  'search',
  'run_command',
];

final class DevelopmentSelfHostingEvidenceContext {
  const DevelopmentSelfHostingEvidenceContext({
    required this.runDirectory,
    required this.launchingRepository,
    required this.sourceHead,
    required this.projectSource,
    required this.taskWorktree,
    required this.taskTitle,
    required this.taskBranch,
    required this.taskBaseline,
    required this.projectId,
    required this.taskId,
    required this.environmentId,
    required this.sessionId,
    required this.profile,
    required this.providerId,
    required this.configuredContext,
    required this.selectedModel,
    required this.maxModelInvocations,
    required this.promptFileHash,
    required this.instructionsFileHash,
    required this.startedAt,
    required this.phaseDurations,
    required this.runnerFailure,
  });

  final Directory runDirectory;
  final Directory launchingRepository;
  final String? sourceHead;
  final Directory? projectSource;
  final Directory? taskWorktree;
  final String taskTitle;
  final String? taskBranch;
  final String? taskBaseline;
  final String? projectId;
  final String? taskId;
  final String? environmentId;
  final String? sessionId;
  final String profile;
  final String providerId;
  final String configuredContext;
  final String? selectedModel;
  final int maxModelInvocations;
  final String? promptFileHash;
  final String? instructionsFileHash;
  final DateTime startedAt;
  final Map<String, int?> phaseDurations;
  final Object? runnerFailure;
}

final class DevelopmentSelfHostingGitEvidence {
  const DevelopmentSelfHostingGitEvidence({
    required this.launchingHead,
    required this.launchingStatus,
    required this.projectHead,
    required this.projectStatus,
    required this.taskHead,
    required this.taskStatus,
    required this.taskDiff,
    required this.taskDiffStat,
    required this.taskDiffCheck,
    required this.taskDiffCheckExitCode,
    required this.taskMergeBase,
    required this.taskAheadBehind,
    required this.changedFiles,
    this.collectionFailures =
        const <DevelopmentSelfHostingGitEvidenceFailure>[],
  });

  final String? launchingHead;
  final String launchingStatus;
  final String? projectHead;
  final String projectStatus;
  final String? taskHead;
  final String taskStatus;
  final String taskDiff;
  final String taskDiffStat;
  final String taskDiffCheck;
  final int? taskDiffCheckExitCode;
  final String? taskMergeBase;
  final String? taskAheadBehind;
  final List<String> changedFiles;
  final List<DevelopmentSelfHostingGitEvidenceFailure> collectionFailures;

  bool get launchingClean => launchingStatus.trim().isEmpty;
  bool get projectClean => projectStatus.trim().isEmpty;
  bool get collectionSucceeded => collectionFailures.isEmpty;

  DevelopmentSelfHostingGitEvidenceException? get failure => collectionSucceeded
      ? null
      : DevelopmentSelfHostingGitEvidenceException(collectionFailures);

  Map<String, Object?> toJson({required String? taskBaseline}) =>
      <String, Object?>{
        'collection': <String, Object?>{
          'succeeded': collectionSucceeded,
          'failures': <Object?>[
            for (final DevelopmentSelfHostingGitEvidenceFailure failure
                in collectionFailures)
              failure.toJson(),
          ],
        },
        'launchingCheckout': <String, Object?>{
          'head': launchingHead,
          'clean': launchingClean,
          'status': launchingStatus,
        },
        'projectSource': <String, Object?>{
          'head': projectHead,
          'clean': projectClean,
          'status': projectStatus,
        },
        'taskWorktree': <String, Object?>{
          'startingHead': taskBaseline,
          'head': taskHead,
          'headMatchesStarting': taskBaseline == null || taskHead == null
              ? null
              : taskHead == taskBaseline,
          'mergeBaseWithStarting': taskMergeBase,
          'aheadBehindStarting': taskAheadBehind,
          'status': taskStatus,
          'diffCheckExitCode': taskDiffCheckExitCode,
          'changedFiles': changedFiles,
          'changedAreas': _changedAreas(changedFiles),
        },
      };
}

final class DevelopmentSelfHostingGitEvidenceFailure {
  const DevelopmentSelfHostingGitEvidenceFailure({
    required this.label,
    required this.arguments,
    required this.exitCode,
    required this.message,
  });

  final String label;
  final List<String> arguments;
  final int exitCode;
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
    'label': label,
    'arguments': arguments,
    'exitCode': exitCode,
    'message': message,
  };
}

final class DevelopmentSelfHostingGitEvidenceException implements Exception {
  DevelopmentSelfHostingGitEvidenceException(
    Iterable<DevelopmentSelfHostingGitEvidenceFailure> failures,
  ) : failures = List<DevelopmentSelfHostingGitEvidenceFailure>.unmodifiable(
        failures,
      );

  final List<DevelopmentSelfHostingGitEvidenceFailure> failures;

  @override
  String toString() =>
      'DevelopmentSelfHostingGitEvidenceException: required Git evidence '
      'failed for ${failures.map((failure) => failure.label).join(', ')}.';
}

Future<DevelopmentSelfHostingGitEvidence>
collectDevelopmentSelfHostingGitEvidence({
  required Directory launchingRepository,
  required Directory? projectSource,
  required Directory? taskWorktree,
  required String? taskBaseline,
}) async {
  final List<DevelopmentSelfHostingGitEvidenceFailure> failures =
      <DevelopmentSelfHostingGitEvidenceFailure>[];
  void requireGitResult(
    String label,
    List<String> arguments,
    _GitResult result, {
    bool Function(_GitResult result)? accepts,
  }) {
    if ((accepts ?? (_GitResult value) => value.exitCode == 0)(result)) return;
    failures.add(
      DevelopmentSelfHostingGitEvidenceFailure(
        label: label,
        arguments: List<String>.unmodifiable(arguments),
        exitCode: result.exitCode,
        message: _gitFailureMessage(result),
      ),
    );
  }

  const List<String> headArguments = <String>['rev-parse', 'HEAD'];
  const List<String> statusArguments = <String>[
    'status',
    '--short',
    '--untracked-files=all',
  ];
  final _GitResult launchingHead = await _git(
    launchingRepository,
    headArguments,
  );
  final _GitResult launchingStatus = await _git(
    launchingRepository,
    statusArguments,
  );
  requireGitResult('launching checkout HEAD', headArguments, launchingHead);
  requireGitResult(
    'launching checkout status',
    statusArguments,
    launchingStatus,
  );
  final _GitResult? projectHead = projectSource == null
      ? null
      : await _git(projectSource, headArguments);
  final _GitResult? projectStatus = projectSource == null
      ? null
      : await _git(projectSource, statusArguments);
  if (projectHead != null) {
    requireGitResult('Project HEAD', headArguments, projectHead);
  }
  if (projectStatus != null) {
    requireGitResult('Project status', statusArguments, projectStatus);
  }
  if (taskWorktree == null) {
    return DevelopmentSelfHostingGitEvidence(
      launchingHead: launchingHead.success ? launchingHead.stdout.trim() : null,
      launchingStatus: launchingStatus.rendered,
      projectHead: projectHead?.success ?? false
          ? projectHead!.stdout.trim()
          : null,
      projectStatus:
          projectStatus?.rendered ?? 'Project setup did not complete.\n',
      taskHead: null,
      taskStatus: 'Task setup did not complete.\n',
      taskDiff: '',
      taskDiffStat: '',
      taskDiffCheck: 'Task setup did not complete.\n',
      taskDiffCheckExitCode: null,
      taskMergeBase: null,
      taskAheadBehind: null,
      changedFiles: const <String>[],
      collectionFailures:
          List<DevelopmentSelfHostingGitEvidenceFailure>.unmodifiable(failures),
    );
  }

  final String baseline = taskBaseline ?? 'HEAD';
  final List<List<String>> taskArguments = <List<String>>[
    headArguments,
    statusArguments,
    <String>['diff', '--binary', baseline, '--'],
    <String>['diff', '--stat', baseline, '--'],
    <String>['diff', '--check', baseline, '--'],
    <String>['merge-base', baseline, 'HEAD'],
    <String>['rev-list', '--left-right', '--count', '$baseline...HEAD'],
    <String>['diff', '--name-only', '-z', baseline, '--'],
    const <String>['ls-files', '-z', '--others', '--exclude-standard'],
  ];
  final List<_GitResult> taskResults = await Future.wait(<Future<_GitResult>>[
    for (final List<String> arguments in taskArguments)
      _git(taskWorktree, arguments),
  ]);
  const List<String> taskLabels = <String>[
    'Task HEAD',
    'Task status',
    'Task diff',
    'Task diff stat',
    'Task diff check',
    'Task merge base',
    'Task ahead/behind relationship',
    'Task tracked changed paths',
    'Task untracked paths',
  ];
  for (var index = 0; index < taskResults.length; index++) {
    requireGitResult(
      taskLabels[index],
      taskArguments[index],
      taskResults[index],
      accepts: index == 4 ? _expectedTrackedDiffCheck : null,
    );
  }
  final List<String> trackedPaths = _nulValues(
    taskResults[7],
    label: taskLabels[7],
    arguments: taskArguments[7],
    failures: failures,
  );
  final List<String> untrackedPaths = _nulValues(
    taskResults[8],
    label: taskLabels[8],
    arguments: taskArguments[8],
    failures: failures,
  );
  final Set<String> changedFiles = <String>{...trackedPaths, ...untrackedPaths};
  final StringBuffer taskDiff = StringBuffer(taskResults[2].rendered);
  final StringBuffer taskDiffStat = StringBuffer(taskResults[3].rendered);
  final StringBuffer taskDiffCheck = StringBuffer(
    '${taskResults[4].stdout}${taskResults[4].stderr}',
  );
  var taskDiffCheckExitCode = taskResults[4].exitCode;
  for (final String path in untrackedPaths) {
    final List<String> untrackedDiffArguments = <String>[
      'diff',
      '--no-index',
      '--binary',
      '--',
      '/dev/null',
      path,
    ];
    final List<String> untrackedStatArguments = <String>[
      'diff',
      '--no-index',
      '--stat',
      '--',
      '/dev/null',
      path,
    ];
    final List<String> untrackedCheckArguments = <String>[
      'diff',
      '--no-index',
      '--check',
      '--',
      '/dev/null',
      path,
    ];
    final _GitResult untrackedDiff = await _git(
      taskWorktree,
      untrackedDiffArguments,
    );
    final _GitResult untrackedStat = await _git(
      taskWorktree,
      untrackedStatArguments,
    );
    final _GitResult untrackedCheck = await _git(
      taskWorktree,
      untrackedCheckArguments,
    );
    requireGitResult(
      'Task untracked diff for ${jsonEncode(path)}',
      untrackedDiffArguments,
      untrackedDiff,
      accepts: _expectedNoIndexDifference,
    );
    requireGitResult(
      'Task untracked diff stat for ${jsonEncode(path)}',
      untrackedStatArguments,
      untrackedStat,
      accepts: _expectedNoIndexDifference,
    );
    requireGitResult(
      'Task untracked diff check for ${jsonEncode(path)}',
      untrackedCheckArguments,
      untrackedCheck,
      accepts: _expectedNoIndexDiffCheck,
    );
    taskDiff.write(_expectedNoIndexDiff(untrackedDiff));
    taskDiffStat.write(_expectedNoIndexDiff(untrackedStat));
    if (untrackedCheck.exitCode != 0 && untrackedCheck.exitCode != 1) {
      if (taskDiffCheck.isNotEmpty &&
          !taskDiffCheck.toString().endsWith('\n')) {
        taskDiffCheck.writeln();
      }
      taskDiffCheck.write('${untrackedCheck.stdout}${untrackedCheck.stderr}');
      if (taskDiffCheckExitCode == 0) {
        taskDiffCheckExitCode = untrackedCheck.exitCode;
      }
    }
  }
  if (taskDiffCheck.isNotEmpty && !taskDiffCheck.toString().endsWith('\n')) {
    taskDiffCheck.writeln();
  }
  taskDiffCheck.writeln('[git exit code: $taskDiffCheckExitCode]');
  final List<String> sortedChangedFiles = changedFiles.toList()..sort();
  return DevelopmentSelfHostingGitEvidence(
    launchingHead: launchingHead.success ? launchingHead.stdout.trim() : null,
    launchingStatus: launchingStatus.rendered,
    projectHead: projectHead?.success ?? false
        ? projectHead!.stdout.trim()
        : null,
    projectStatus: projectStatus?.rendered ?? '',
    taskHead: taskResults[0].success ? taskResults[0].stdout.trim() : null,
    taskStatus: taskResults[1].rendered,
    taskDiff: taskDiff.toString(),
    taskDiffStat: taskDiffStat.toString(),
    taskDiffCheck: taskDiffCheck.toString(),
    taskDiffCheckExitCode: taskDiffCheckExitCode,
    taskMergeBase: taskResults[5].success ? taskResults[5].stdout.trim() : null,
    taskAheadBehind: taskResults[6].success
        ? taskResults[6].stdout.trim()
        : null,
    changedFiles: List<String>.unmodifiable(sortedChangedFiles),
    collectionFailures:
        List<DevelopmentSelfHostingGitEvidenceFailure>.unmodifiable(failures),
  );
}

final class DevelopmentSelfHostingEvidenceWriter {
  const DevelopmentSelfHostingEvidenceWriter();

  Future<Map<String, Object?>> write({
    required DevelopmentSelfHostingEvidenceContext context,
    required DevelopmentSelfHostingRunResult? result,
    required DevelopmentSelfHostingGitEvidence git,
  }) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    await context.runDirectory.create(recursive: true);
    final Directory gitDirectory = Directory(
      '${context.runDirectory.path}/git',
    );
    await gitDirectory.create(recursive: true);

    final Map<String, Object?> journal = developmentSelfHostingJournalJson(
      result,
    );
    final Map<String, Object?> summary = developmentSelfHostingSummaryJson(
      result: result,
      selectedModel: context.selectedModel,
      git: git,
      taskBaseline: context.taskBaseline,
      runnerFailure: context.runnerFailure,
    );
    await Future.wait(<Future<void>>[
      _writeJson(File('${context.runDirectory.path}/journal.json'), journal),
      _writeJson(File('${context.runDirectory.path}/summary.json'), summary),
      File(
        '${context.runDirectory.path}/summary.md',
      ).writeAsString(developmentSelfHostingSummaryMarkdown(summary)),
      File('${gitDirectory.path}/status.txt').writeAsString(git.taskStatus),
      File('${gitDirectory.path}/diff.patch').writeAsString(git.taskDiff),
      File(
        '${gitDirectory.path}/diff-stat.txt',
      ).writeAsString(git.taskDiffStat),
      File(
        '${gitDirectory.path}/diff-check.txt',
      ).writeAsString(git.taskDiffCheck),
      File('${gitDirectory.path}/changed-files.txt').writeAsString(
        git.changedFiles.isEmpty
            ? ''
            : '${git.changedFiles.map(jsonEncode).join('\n')}\n',
      ),
      File('${gitDirectory.path}/collection-errors.txt').writeAsString(
        git.collectionFailures.isEmpty
            ? ''
            : '${git.collectionFailures.map((failure) => '${failure.label}: ${failure.message}').join('\n')}\n',
      ),
      File(
        '${gitDirectory.path}/project-status.txt',
      ).writeAsString(git.projectStatus),
      File(
        '${gitDirectory.path}/launching-status.txt',
      ).writeAsString(git.launchingStatus),
      _writeJson(
        File('${gitDirectory.path}/facts.json'),
        git.toJson(taskBaseline: context.taskBaseline),
      ),
    ]);
    final Object? failure = context.runnerFailure ?? result?.run.failure;
    Map<String, Object?> buildManifest(DateTime endedAt, int evidenceDuration) {
      final Map<String, int?> phaseDurations = <String, int?>{
        ...context.phaseDurations,
        'evidenceReportGeneration':
            (context.phaseDurations['evidenceReportGeneration'] ?? 0) +
            evidenceDuration,
      };
      return <String, Object?>{
        r'$schema': 'dev.adele.development-self-hosting.manifest',
        'schemaVersion': developmentSelfHostingReportSchemaVersion,
        'runner': <String, Object?>{
          'name': 'adele_self_host',
          'version': developmentSelfHostingReportSchemaVersion,
        },
        'provenance': <String, Object?>{
          'startingSourceSha': context.sourceHead,
          'launchingCheckoutPath': context.launchingRepository.path,
          'projectSourcePath': context.projectSource?.path,
          'taskWorktreePath': context.taskWorktree?.path,
          'taskTitle': context.taskTitle,
          'taskBranch': context.taskBranch,
          'taskBaseline': context.taskBaseline,
          'projectId': context.projectId,
          'taskId': context.taskId,
          'environmentId': context.environmentId,
          'sessionId': context.sessionId,
          'runId': result?.run.id.value,
          'profile': context.profile,
          'providerId': context.providerId,
          'configuredContext': context.configuredContext,
          'selectedModel': context.selectedModel,
          'maxModelInvocations': context.maxModelInvocations,
          'promptFileSha256': context.promptFileHash,
          'instructionsFileSha256': context.instructionsFileHash,
        },
        'timing': <String, Object?>{
          'startedAt': context.startedAt.toUtc().toIso8601String(),
          'endedAt': endedAt.toUtc().toIso8601String(),
          'phaseDurationsMilliseconds': phaseDurations,
        },
        'terminal': <String, Object?>{
          'runState': result?.run.state.name,
          'failure': _failureSummary(failure),
        },
      };
    }

    final File manifestFile = File(
      '${context.runDirectory.path}/manifest.json',
    );
    await _writeJson(
      manifestFile,
      buildManifest(DateTime.now(), stopwatch.elapsedMilliseconds),
    );
    stopwatch.stop();
    final Map<String, Object?> manifest = buildManifest(
      DateTime.now(),
      stopwatch.elapsedMilliseconds,
    );
    await _writeJson(manifestFile, manifest);
    final File runnerLog = File('${context.runDirectory.path}/runner.log');
    if (!await runnerLog.exists()) await runnerLog.writeAsString('');
    return manifest;
  }
}

Map<String, Object?> developmentSelfHostingJournalJson(
  DevelopmentSelfHostingRunResult? result,
) => <String, Object?>{
  r'$schema': 'dev.adele.development-self-hosting.journal',
  'schemaVersion': developmentSelfHostingReportSchemaVersion,
  'run': result == null
      ? null
      : <String, Object?>{
          'id': result.run.id.value,
          'sessionId': result.run.sessionId.value,
          'state': result.run.state.name,
          'failure': developmentSelfHostingErrorJson(result.run.failure),
          'executionFailure': developmentSelfHostingErrorJson(
            result.executionFailure,
          ),
        },
  'sessionEntries': result == null
      ? const <Object?>[]
      : <Object?>[
          for (final SessionEntry entry in result.session.snapshot().entries)
            <String, Object?>{
              'role': switch (entry) {
                UserSessionMessage() => 'user',
                AssistantSessionMessage() => 'assistant',
              },
              'content': entry.content,
            },
        ],
  'records': result == null
      ? const <Object?>[]
      : <Object?>[
          for (final ExecutionEventRecord record in result.run.journal.records)
            <String, Object?>{
              'sequence': record.sequence,
              ..._eventJson(record.event),
            },
        ],
};

Map<String, Object?> developmentSelfHostingSummaryJson({
  required DevelopmentSelfHostingRunResult? result,
  required String? selectedModel,
  required DevelopmentSelfHostingGitEvidence git,
  String? taskBaseline,
  Object? runnerFailure,
}) {
  final List<ExecutionEventRecord> records =
      result?.run.journal.records ?? const <ExecutionEventRecord>[];
  final List<_ModelTerminal> modelTerminals = <_ModelTerminal>[];
  final List<ModelInvocationStarted> modelStarts = <ModelInvocationStarted>[];
  final List<_Proposal> proposals = <_Proposal>[];
  final Map<ProviderToolProposal, ToolInvocationPrepared> preparedByProposal =
      HashMap<ProviderToolProposal, ToolInvocationPrepared>.identity();
  final List<({int sequence, ToolInvocationPrepared event})> prepared =
      <({int sequence, ToolInvocationPrepared event})>[];
  final Map<ToolInvocationId, ExecutionEventRecord> terminalByInvocation =
      <ToolInvocationId, ExecutionEventRecord>{};
  final Set<ToolInvocationId> executed = <ToolInvocationId>{};

  for (final ExecutionEventRecord record in records) {
    switch (record.event) {
      case final ModelInvocationStarted event:
        modelStarts.add(event);
      case final ModelInvocationSettled event:
        modelTerminals.add(
          _ModelTerminal(
            invocationId: event.invocationId,
            terminalState: event.settlement.name,
            effectiveModel: event.metadata.effectiveModel,
            usage: event.metadata.usage,
            failure: null,
          ),
        );
      case final ModelInvocationFailed event:
        modelTerminals.add(
          _ModelTerminal(
            invocationId: event.invocationId,
            terminalState: 'failed',
            effectiveModel: event.semanticTerminalMetadata?.effectiveModel,
            usage: event.semanticTerminalMetadata?.usage,
            failure: event.error,
          ),
        );
      case ModelOutputObserved(
        :final invocationId,
        item: final ModelToolProposalOutput item,
      ):
        proposals.add(
          _Proposal(
            sequence: record.sequence,
            modelInvocationId: invocationId,
            output: item,
          ),
        );
      case final ToolInvocationPrepared event:
        preparedByProposal[event.invocation.proposal] = event;
        prepared.add((sequence: record.sequence, event: event));
      case final ToolExecutionStarted event:
        executed.add(event.invocationId);
      case ToolExecutionCompleted(:final invocationId) ||
          ToolInvocationCompleted(:final invocationId):
        terminalByInvocation[invocationId] = record;
      default:
        break;
    }
  }

  final List<Map<String, Object?>> proposalJson = <Map<String, Object?>>[
    for (final _Proposal proposal in proposals)
      <String, Object?>{
        'sequence': proposal.sequence,
        'modelInvocationId': proposal.modelInvocationId.value,
        'providerCallId': proposal.output.proposal.providerCallId,
        'alias': proposal.output.proposal.alias,
        'arguments': proposal.output.proposal.arguments,
        'prepared': preparedByProposal.containsKey(proposal.output.proposal),
        'toolInvocationId':
            preparedByProposal[proposal.output.proposal]?.invocation.id.value,
      },
  ];
  final List<Map<String, Object?>> attemptJson = <Map<String, Object?>>[];
  final Map<String, Map<String, Object?>> aliases =
      <String, Map<String, Object?>>{
        for (final String alias in developmentSelfHostingToolAliases)
          alias: _emptyAliasSummary(alias),
      };
  for (final Map<String, Object?> proposal in proposalJson) {
    final String alias = proposal['alias']! as String;
    final Map<String, Object?> summary = aliases.putIfAbsent(
      alias,
      () => _emptyAliasSummary(alias),
    );
    summary['proposalCount'] = (summary['proposalCount']! as int) + 1;
  }
  var totalBytesRead = 0;
  var failedToolCount = 0;
  var revisionConflictCount = 0;
  for (final ({int sequence, ToolInvocationPrepared event}) item in prepared) {
    final ToolInvocation invocation = item.event.invocation;
    final String alias = invocation.tool.modelDefinition.alias;
    final Map<String, Object?> aliasSummary = aliases.putIfAbsent(
      alias,
      () => _emptyAliasSummary(alias),
    );
    aliasSummary['preparedCount'] = (aliasSummary['preparedCount']! as int) + 1;
    final bool wasExecuted = executed.contains(invocation.id);
    if (wasExecuted) {
      aliasSummary['executedCount'] =
          (aliasSummary['executedCount']! as int) + 1;
    }
    final ExecutionEventRecord? terminalRecord =
        terminalByInvocation[invocation.id];
    final ToolOutcome? outcome = switch (terminalRecord?.event) {
      ToolExecutionCompleted(:final outcome) ||
      ToolInvocationCompleted(:final outcome) => outcome,
      _ => null,
    };
    if (outcome != null) {
      aliasSummary['terminalCount'] =
          (aliasSummary['terminalCount']! as int) + 1;
      switch (outcome.disposition) {
        case ToolOutcomeDisposition.success:
          aliasSummary['terminalSuccessCount'] =
              (aliasSummary['terminalSuccessCount']! as int) + 1;
        case ToolOutcomeDisposition.failure:
          aliasSummary['terminalFailureCount'] =
              (aliasSummary['terminalFailureCount']! as int) + 1;
          failedToolCount++;
        default:
          aliasSummary['terminalOtherCount'] =
              (aliasSummary['terminalOtherCount']! as int) + 1;
      }
      if (outcome.hostData['code'] == environmentRevisionConflictCode) {
        revisionConflictCount++;
      }
      if (alias == 'read_file' &&
          outcome.disposition == ToolOutcomeDisposition.success &&
          outcome.hostData['sizeBytes'] is int) {
        totalBytesRead += outcome.hostData['sizeBytes']! as int;
      }
    }
    attemptJson.add(<String, Object?>{
      'preparedSequence': item.sequence,
      'terminalSequence': terminalRecord?.sequence,
      'invocationId': invocation.id.value,
      'providerCallId': invocation.proposal.providerCallId,
      'alias': alias,
      'toolId': invocation.toolId.value,
      'proposedArguments': invocation.proposal.arguments,
      'canonicalArguments': invocation.canonicalArguments,
      'executed': wasExecuted,
      'terminalEvent': switch (terminalRecord?.event) {
        ToolExecutionCompleted() => 'executionCompleted',
        ToolInvocationCompleted() => 'invocationCompleted',
        _ => null,
      },
      'disposition': outcome?.disposition.name,
      'failureKind': outcome?.failureKind?.name,
      'effectCertainty': outcome?.effectCertainty.name,
      'failureCode': outcome?.hostData['code'],
      'evidence': _attemptEvidence(alias, invocation, outcome),
    });
  }

  final List<int?> inputTokens = modelTerminals
      .map((_ModelTerminal terminal) => terminal.usage?.inputTokens)
      .toList(growable: false);
  final List<int?> outputTokens = modelTerminals
      .map((_ModelTerminal terminal) => terminal.usage?.outputTokens)
      .toList(growable: false);
  final List<int?> cacheReadTokens = modelTerminals
      .map((_ModelTerminal terminal) => terminal.usage?.cacheReadTokens)
      .toList(growable: false);
  final List<int?> cacheWriteTokens = modelTerminals
      .map((_ModelTerminal terminal) => terminal.usage?.cacheWriteTokens)
      .toList(growable: false);
  int? previousInputTokens;
  final List<Map<String, Object?>> modelInvocationJson =
      <Map<String, Object?>>[];
  for (final _ModelTerminal terminal in modelTerminals) {
    final int? currentInputTokens = terminal.usage?.inputTokens;
    final int? growth =
        previousInputTokens == null || currentInputTokens == null
        ? null
        : currentInputTokens - previousInputTokens;
    if (currentInputTokens != null) previousInputTokens = currentInputTokens;
    modelInvocationJson.add(<String, Object?>{
      'invocationId': terminal.invocationId.value,
      'terminalState': terminal.terminalState,
      'effectiveModel': terminal.effectiveModel,
      'usage': _usageJson(terminal.usage),
      'inputTokenGrowthFromPreviousReported': growth,
      'failure': developmentSelfHostingErrorJson(terminal.failure),
    });
  }
  final List<AssistantSessionMessage> assistantEntries = result == null
      ? const <AssistantSessionMessage>[]
      : result.session
            .snapshot()
            .entries
            .whereType<AssistantSessionMessage>()
            .toList(growable: false);
  final String? finalAssistantResponse = assistantEntries.isEmpty
      ? null
      : assistantEntries.last.content;
  final Object? summaryFailure = result?.run.failure ?? runnerFailure;

  return <String, Object?>{
    r'$schema': 'dev.adele.development-self-hosting.summary',
    'schemaVersion': developmentSelfHostingReportSchemaVersion,
    'run': <String, Object?>{
      'terminalState': result?.run.state.name,
      'failure': developmentSelfHostingErrorJson(summaryFailure),
      'startedModelInvocations': modelStarts.length,
      'terminalModelInvocations': modelTerminals.length,
      'completedModelInvocations': modelTerminals
          .where((_ModelTerminal value) => value.terminalState == 'completed')
          .length,
      'failedModelInvocations': modelTerminals
          .where((_ModelTerminal value) => value.terminalState == 'failed')
          .length,
      'selectedModel': selectedModel,
      'effectiveModelSequence': <Object?>[
        for (final _ModelTerminal terminal in modelTerminals)
          terminal.effectiveModel,
      ],
      'hasFinalAssistantResponse': finalAssistantResponse != null,
      'finalAssistantResponse': finalAssistantResponse,
    },
    'modelInvocations': modelInvocationJson,
    'usageTotals': <String, Object?>{
      'inputTokens': _sumKnown(inputTokens),
      'outputTokens': _sumKnown(outputTokens),
      'cacheReadTokens': _sumKnown(cacheReadTokens),
      'cacheWriteTokens': _sumKnown(cacheWriteTokens),
      'terminalInvocations': modelTerminals.length,
      'reportedInputInvocations': inputTokens.whereType<int>().length,
      'reportedOutputInvocations': outputTokens.whereType<int>().length,
      'reportedCacheReadInvocations': cacheReadTokens.whereType<int>().length,
      'reportedCacheWriteInvocations': cacheWriteTokens.whereType<int>().length,
      'inputTotalComplete':
          inputTokens.whereType<int>().length == modelTerminals.length,
      'outputTotalComplete':
          outputTokens.whereType<int>().length == modelTerminals.length,
      'cacheReadTotalComplete':
          cacheReadTokens.whereType<int>().length == modelTerminals.length,
      'cacheWriteTotalComplete':
          cacheWriteTokens.whereType<int>().length == modelTerminals.length,
      'inputTokenSequence': inputTokens,
    },
    'tools': <String, Object?>{
      'aliases': aliases,
      'proposals': proposalJson,
      'unpreparedProposals': proposalJson
          .where((Map<String, Object?> value) => value['prepared'] == false)
          .toList(growable: false),
      'attempts': attemptJson,
    },
    'aggregates': <String, Object?>{
      'totalBytesRead': totalBytesRead,
      'toolProposalCount': proposalJson.length,
      'preparedToolCount': prepared.length,
      'executedToolCount': executed.length,
      'failedToolCount': failedToolCount,
      'revisionConflictCount': revisionConflictCount,
      'commandCount': attemptJson
          .where(
            (Map<String, Object?> value) => value['alias'] == 'run_command',
          )
          .length,
    },
    'git': git.toJson(taskBaseline: taskBaseline),
  };
}

String developmentSelfHostingSummaryMarkdown(Map<String, Object?> summary) {
  final StringBuffer output = StringBuffer('# ADELE Self-Hosting Summary\n\n');
  final Map<String, Object?> run = summary['run']! as Map<String, Object?>;
  final Map<String, Object?> aggregates =
      summary['aggregates']! as Map<String, Object?>;
  final Map<String, Object?> usage =
      summary['usageTotals']! as Map<String, Object?>;
  final List<Object?> modelInvocations =
      summary['modelInvocations']! as List<Object?>;
  final Map<String, Object?> tools = summary['tools']! as Map<String, Object?>;
  final Map<String, Object?> aliases =
      tools['aliases']! as Map<String, Object?>;
  output
    ..writeln('## Run')
    ..writeln()
    ..writeln('| Fact | Value |')
    ..writeln('| --- | --- |')
    ..writeln('| Terminal state | ${run['terminalState'] ?? 'unavailable'} |')
    ..writeln('| Selected model | ${run['selectedModel'] ?? 'unavailable'} |')
    ..writeln(
      '| Effective models | '
      '${(run['effectiveModelSequence']! as List<Object?>).join(' -> ')} |',
    )
    ..writeln(
      '| Completed model invocations | ${run['completedModelInvocations']} |',
    )
    ..writeln(
      '| Final assistant response | '
      '${run['hasFinalAssistantResponse'] == true ? 'present' : 'absent'} |',
    )
    ..writeln('| Failure | ${_markdownValue(run['failure'])} |')
    ..writeln()
    ..writeln('## Model Usage')
    ..writeln()
    ..writeln(
      '| Invocation | State | Effective model | Input | Growth | Output | Cache read |',
    )
    ..writeln('| --- | --- | --- | ---: | ---: | ---: | ---: |');
  for (final Object? value in modelInvocations) {
    final Map<String, Object?> invocation = value! as Map<String, Object?>;
    final Map<String, Object?>? invocationUsage =
        invocation['usage'] as Map<String, Object?>?;
    output.writeln(
      '| `${invocation['invocationId']}` | ${invocation['terminalState']} | '
      '${invocation['effectiveModel'] ?? 'unreported'} | '
      '${invocationUsage?['inputTokens'] ?? 'unreported'} | '
      '${invocation['inputTokenGrowthFromPreviousReported'] ?? 'unreported'} | '
      '${invocationUsage?['outputTokens'] ?? 'unreported'} | '
      '${invocationUsage?['cacheReadTokens'] ?? 'unreported'} |',
    );
  }
  output
    ..writeln()
    ..writeln(
      'Reported totals: input `${usage['inputTokens']}` '
      '(complete: `${usage['inputTotalComplete']}`), output '
      '`${usage['outputTokens']}` (complete: `${usage['outputTotalComplete']}`), '
      'cache read `${usage['cacheReadTokens']}` '
      '(complete: `${usage['cacheReadTotalComplete']}`), cache write '
      '`${usage['cacheWriteTokens']}` '
      '(complete: `${usage['cacheWriteTotalComplete']}`).',
    )
    ..writeln()
    ..writeln('## Aggregates')
    ..writeln()
    ..writeln('| Fact | Value |')
    ..writeln('| --- | ---: |')
    ..writeln('| Tool proposals | ${aggregates['toolProposalCount']} |')
    ..writeln('| Prepared tools | ${aggregates['preparedToolCount']} |')
    ..writeln('| Executed tools | ${aggregates['executedToolCount']} |')
    ..writeln('| Failed tools | ${aggregates['failedToolCount']} |')
    ..writeln('| Revision conflicts | ${aggregates['revisionConflictCount']} |')
    ..writeln('| Commands | ${aggregates['commandCount']} |')
    ..writeln('| Bytes read | ${aggregates['totalBytesRead']} |')
    ..writeln()
    ..writeln('## Tools')
    ..writeln()
    ..writeln(
      '| Alias | Proposed | Prepared | Executed | Success | Failure | Other |',
    )
    ..writeln('| --- | ---: | ---: | ---: | ---: | ---: | ---: |');
  for (final MapEntry<String, Object?> entry in aliases.entries) {
    final Map<String, Object?> alias = entry.value! as Map<String, Object?>;
    output.writeln(
      '| `${entry.key}` | ${alias['proposalCount']} | '
      '${alias['preparedCount']} | ${alias['executedCount']} | '
      '${alias['terminalSuccessCount']} | ${alias['terminalFailureCount']} | '
      '${alias['terminalOtherCount']} |',
    );
  }
  final List<Object?> unprepared =
      tools['unpreparedProposals']! as List<Object?>;
  output
    ..writeln()
    ..writeln('## Unprepared Proposals')
    ..writeln();
  if (unprepared.isEmpty) {
    output.writeln('None.');
  } else {
    for (final Object? value in unprepared) {
      final Map<String, Object?> proposal = value! as Map<String, Object?>;
      output.writeln(
        '- `${proposal['alias']}` from `${proposal['modelInvocationId']}`: '
        '${_proposalMarkdownArguments(proposal['alias']! as String, proposal['arguments']! as Map<String, Object?>)}',
      );
    }
  }
  output
    ..writeln()
    ..writeln('## Tool Attempts')
    ..writeln();
  final List<Object?> attempts = tools['attempts']! as List<Object?>;
  if (attempts.isEmpty) {
    output.writeln('None.');
  } else {
    for (final Object? value in attempts) {
      final Map<String, Object?> attempt = value! as Map<String, Object?>;
      output.writeln(
        '- `${attempt['alias']}` `${attempt['invocationId']}`: '
        '${attempt['disposition'] ?? 'unterminated'}; '
        '${_attemptMarkdown(attempt['evidence']! as Map<String, Object?>)}',
      );
    }
  }
  final Map<String, Object?> git = summary['git']! as Map<String, Object?>;
  final Map<String, Object?> collection =
      git['collection']! as Map<String, Object?>;
  final Map<String, Object?> task =
      git['taskWorktree']! as Map<String, Object?>;
  output
    ..writeln()
    ..writeln('## Git Evidence')
    ..writeln()
    ..writeln('- Collection succeeded: `${collection['succeeded']}`')
    ..writeln('- Diff check exit code: `${task['diffCheckExitCode']}`')
    ..writeln(
      '- Changed areas: `${(task['changedAreas']! as List).join(', ')}`',
    )
    ..writeln('- Changed files:');
  final List<Object?> changedFiles = task['changedFiles']! as List<Object?>;
  if (changedFiles.isEmpty) {
    output.writeln('None.');
  } else {
    for (final Object? path in changedFiles) {
      output.writeln('- `$path`');
    }
  }
  final Object? finalResponse = run['finalAssistantResponse'];
  if (finalResponse is String) {
    output
      ..writeln()
      ..writeln('## Final Assistant Response')
      ..writeln()
      ..writeln(_boundedMarkdownText(finalResponse.trim()))
      ..writeln();
  }
  return output.toString();
}

Map<String, Object?>? developmentSelfHostingErrorJson(Object? error) {
  if (error == null) return null;
  if (error is ModelFailure) {
    return <String, Object?>{
      'type': 'ModelFailure',
      'kind': error.kind.name,
      'providerCode': error.providerCode,
      'providerMessage': error.providerMessage,
      'providerDetails': error.providerDetails,
      'cause': _causeJson(error.cause),
    };
  }
  if (error is ModelInvocationIncomplete) {
    return <String, Object?>{
      'type': 'ModelInvocationIncomplete',
      'reason': error.reason.name,
      'metadata': _metadataJson(error.metadata),
    };
  }
  if (error is ModelInvocationLimitExceeded) {
    return <String, Object?>{
      'type': 'ModelInvocationLimitExceeded',
      'maximum': error.maximum,
      'message': error.toString(),
    };
  }
  if (error is EnvironmentFailure) {
    return <String, Object?>{
      'type': 'EnvironmentFailure',
      'code': error.code,
      'message': error.message,
      'details': error.details,
    };
  }
  return <String, Object?>{
    'type': error.runtimeType.toString(),
    'message': error.toString(),
  };
}

Map<String, Object?> _eventJson(ExecutionEvent event) {
  if (event is RunStarted) return <String, Object?>{'event': 'runStarted'};
  if (event is RunWaiting) {
    return <String, Object?>{
      'event': 'runWaiting',
      'interruptionIds': <Object?>[
        for (final RunInterruptionId id in event.interruptionIds) id.value,
      ],
    };
  }
  if (event is RunResumed) return <String, Object?>{'event': 'runResumed'};
  if (event is RunCompleted) return <String, Object?>{'event': 'runCompleted'};
  if (event is RunFailed) {
    return <String, Object?>{
      'event': 'runFailed',
      'error': developmentSelfHostingErrorJson(event.error),
    };
  }
  if (event is RunCancelled) return <String, Object?>{'event': 'runCancelled'};
  if (event is ModelInvocationStarted) {
    return <String, Object?>{
      'event': 'modelInvocationStarted',
      'invocationId': event.invocationId.value,
    };
  }
  if (event is ModelObservationObserved) {
    return <String, Object?>{
      'event': 'modelObservationObserved',
      'invocationId': event.invocationId.value,
      'observation': switch (event.observation) {
        ModelTextDeltaObservation(:final delta, :final providerItemId) =>
          <String, Object?>{
            'kind': 'textDelta',
            'delta': delta,
            'providerItemId': providerItemId,
          },
      },
    };
  }
  if (event is ModelOutputObserved) {
    return <String, Object?>{
      'event': 'modelOutputObserved',
      'invocationId': event.invocationId.value,
      'output': _modelOutputJson(event.item),
    };
  }
  if (event is ModelInvocationSettled) {
    return <String, Object?>{
      'event': 'modelInvocationSettled',
      'invocationId': event.invocationId.value,
      'settlement': event.settlement.name,
      'incompleteReason': event.incompleteReason?.name,
      'metadata': _metadataJson(event.metadata),
    };
  }
  if (event is ModelInvocationFailed) {
    return <String, Object?>{
      'event': 'modelInvocationFailed',
      'invocationId': event.invocationId.value,
      'error': developmentSelfHostingErrorJson(event.error),
      'semanticTerminalMetadata': event.semanticTerminalMetadata == null
          ? null
          : _metadataJson(event.semanticTerminalMetadata!),
    };
  }
  if (event is ToolInvocationPrepared) {
    return <String, Object?>{
      'event': 'toolInvocationPrepared',
      'invocation': _invocationJson(event.invocation),
    };
  }
  if (event is ToolPolicyEvaluated) {
    return <String, Object?>{
      'event': 'toolPolicyEvaluated',
      'invocationId': event.invocationId.value,
      'decision': event.decision.name,
      'effects': _effectsJson(event.effects),
    };
  }
  if (event is RunInterrupted) {
    return <String, Object?>{
      'event': 'runInterrupted',
      'interruption': _interruptionJson(event.interruption),
    };
  }
  if (event is RunInterruptionResolved) {
    return <String, Object?>{
      'event': 'runInterruptionResolved',
      'interruption': _interruptionJson(event.interruption),
      'resolution': _resolutionJson(event.resolution),
    };
  }
  if (event is ToolExecutionStarted) {
    return <String, Object?>{
      'event': 'toolExecutionStarted',
      'invocationId': event.invocationId.value,
    };
  }
  if (event is ToolProgressObserved) {
    return <String, Object?>{
      'event': 'toolProgressObserved',
      'invocationId': event.invocationId.value,
      'progress': <String, Object?>{
        'kind': event.progress.kind.name,
        'content': event.progress.content,
      },
    };
  }
  if (event is ToolExecutionCompleted) {
    return <String, Object?>{
      'event': 'toolExecutionCompleted',
      'invocationId': event.invocationId.value,
      'outcome': _outcomeJson(event.outcome),
    };
  }
  if (event is ToolInvocationCompleted) {
    return <String, Object?>{
      'event': 'toolInvocationCompleted',
      'invocationId': event.invocationId.value,
      'outcome': _outcomeJson(event.outcome),
    };
  }
  throw StateError('Unsupported Run journal event: ${event.runtimeType}.');
}

Map<String, Object?> _modelOutputJson(ModelOutputItem item) => switch (item) {
  ModelTextOutput(
    :final content,
    :final providerItemId,
    :final providerNativeMetadata,
  ) =>
    <String, Object?>{
      'kind': 'text',
      'content': content,
      'providerItemId': providerItemId,
      'providerNativeMetadata': _nativeEnvelopeJson(providerNativeMetadata),
    },
  ModelToolProposalOutput(
    :final proposal,
    :final providerItemId,
    :final providerNativeMetadata,
  ) =>
    <String, Object?>{
      'kind': 'toolProposal',
      'proposal': _proposalJson(proposal),
      'providerItemId': providerItemId,
      'providerNativeMetadata': _nativeEnvelopeJson(providerNativeMetadata),
    },
  ModelNativeOutput(:final providerNativeMetadata, :final providerItemId) =>
    <String, Object?>{
      'kind': 'providerNative',
      'providerItemId': providerItemId,
      'providerNativeMetadata': _nativeEnvelopeJson(providerNativeMetadata),
    },
};

Map<String, Object?> _invocationJson(ToolInvocation invocation) =>
    <String, Object?>{
      'id': invocation.id.value,
      'proposal': _proposalJson(invocation.proposal),
      'tool': <String, Object?>{
        'id': invocation.toolId.value,
        'description': invocation.tool.definition.description,
        'alias': invocation.tool.modelDefinition.alias,
        'modelDescription': invocation.tool.modelDefinition.description,
        'argumentsSchema': invocation.tool.modelDefinition.argumentsSchema,
      },
      'canonicalArguments': invocation.canonicalArguments,
      'context': <String, Object?>{
        'runId': invocation.context.runId.value,
        'sessionId': invocation.context.sessionId.value,
      },
    };

Map<String, Object?> _proposalJson(ProviderToolProposal proposal) =>
    <String, Object?>{
      'providerCallId': proposal.providerCallId,
      'alias': proposal.alias,
      'arguments': proposal.arguments,
    };

Map<String, Object?> _outcomeJson(ToolOutcome outcome) => <String, Object?>{
  'disposition': outcome.disposition.name,
  'failureKind': outcome.failureKind?.name,
  'effectCertainty': outcome.effectCertainty.name,
  'modelContent': outcome.modelContent,
  'hostData': outcome.hostData,
  'hostDiagnostic': outcome.hostDiagnostic,
  'cause': _causeJson(outcome.cause),
};

Map<String, Object?> _effectsJson(
  EffectDescription effects,
) => <String, Object?>{
  'effects': effects.effects.map((ToolEffect value) => value.name).toList()
    ..sort(),
  'targets': <Object?>[
    for (final EffectTarget target in effects.targets) target.uri.toString(),
  ],
  'summary': effects.summary,
  'uncertainty': effects.uncertainty.name,
};

Map<String, Object?> _interruptionJson(RunInterruption interruption) =>
    switch (interruption) {
      ToolApprovalInterruption(:final id, :final invocation, :final effects) =>
        <String, Object?>{
          'type': 'toolApproval',
          'id': id.value,
          'invocation': _invocationJson(invocation),
          'effects': _effectsJson(effects),
        },
    };

Map<String, Object?> _resolutionJson(RunInterruptionResolution resolution) =>
    switch (resolution) {
      ToolApprovalResolution(
        :final interruptionId,
        :final toolInvocationId,
        :final approved,
      ) =>
        <String, Object?>{
          'type': 'toolApproval',
          'interruptionId': interruptionId.value,
          'toolInvocationId': toolInvocationId.value,
          'approved': approved,
        },
    };

Map<String, Object?> _metadataJson(ModelTerminalMetadata metadata) =>
    <String, Object?>{
      'effectiveModel': metadata.effectiveModel,
      'providerResponseId': metadata.providerResponseId,
      'providerRequestId': metadata.providerRequestId,
      'providerStopReason': metadata.providerStopReason,
      'usage': _usageJson(metadata.usage),
      'providerNativeState': _nativeEnvelopeJson(metadata.providerNativeState),
    };

Map<String, Object?>? _usageJson(ModelUsage? usage) => usage == null
    ? null
    : <String, Object?>{
        'inputTokens': usage.inputTokens,
        'outputTokens': usage.outputTokens,
        'cacheReadTokens': usage.cacheReadTokens,
        'cacheWriteTokens': usage.cacheWriteTokens,
        'providerDetails': usage.providerDetails,
      };

Map<String, Object?>? _nativeEnvelopeJson(ModelNativeEnvelope? envelope) =>
    envelope == null
    ? null
    : <String, Object?>{
        'kind': envelope.kind,
        'compatibility': envelope.compatibility,
        'data': envelope.data,
      };

Map<String, Object?>? _causeJson(Object? cause) => cause == null
    ? null
    : <String, Object?>{
        'type': cause.runtimeType.toString(),
        'message': cause.toString(),
      };

Map<String, Object?>? _failureSummary(Object? failure) {
  final Map<String, Object?>? full = developmentSelfHostingErrorJson(failure);
  if (full == null) return null;
  final String message = switch (failure) {
    ModelFailure(:final kind, :final providerMessage) =>
      providerMessage ?? 'Model provider failure: ${kind.name}.',
    ModelInvocationIncomplete(:final reason) =>
      'Model invocation ended incomplete: ${reason.name}.',
    EnvironmentFailure(:final message) => message,
    _ => full['message']?.toString() ?? failure.toString(),
  };
  return <String, Object?>{
    'type': full['type'],
    if (full.containsKey('kind')) 'kind': full['kind'],
    if (full.containsKey('providerCode')) 'providerCode': full['providerCode'],
    'message': message,
  };
}

Map<String, Object?> _emptyAliasSummary(String alias) => <String, Object?>{
  'alias': alias,
  'proposalCount': 0,
  'preparedCount': 0,
  'executedCount': 0,
  'terminalCount': 0,
  'terminalSuccessCount': 0,
  'terminalFailureCount': 0,
  'terminalOtherCount': 0,
};

Map<String, Object?> _attemptEvidence(
  String alias,
  ToolInvocation invocation,
  ToolOutcome? outcome,
) {
  final Map<String, Object?> arguments = invocation.canonicalArguments;
  final Map<String, Object?> hostData =
      outcome?.hostData ?? const <String, Object?>{};
  return switch (alias) {
    'search' => <String, Object?>{
      'query': arguments['query'],
      'path': arguments['path'] ?? hostData['path'] ?? hostData['scope'],
      'matchCount': switch (hostData['matches']) {
        final List<Object?> matches => matches.length,
        _ => null,
      },
      'incomplete': hostData['incomplete'],
      'truncated': hostData['truncated'],
    },
    'read_file' => <String, Object?>{
      'relativePath': arguments['relativePath'] ?? hostData['relativePath'],
      'returnedByteSize': hostData['sizeBytes'],
      'revision': hostData['revision'],
    },
    'apply_patch' => <String, Object?>{
      'relativePath': arguments['relativePath'] ?? hostData['relativePath'],
      'expectedRevision': arguments['expectedRevision'],
      'resultingRevision': hostData['newRevision'],
      'failureCode': hostData['code'],
    },
    'create_file' => <String, Object?>{
      'relativePath': arguments['relativePath'] ?? hostData['relativePath'],
      'resultingRevision': hostData['revision'],
      'failureCode': hostData['code'],
    },
    'delete_file' => <String, Object?>{
      'relativePath': arguments['relativePath'] ?? hostData['relativePath'],
      'expectedRevision': arguments['expectedRevision'],
      'failureCode': hostData['code'],
    },
    'run_command' => <String, Object?>{
      'program': arguments['program'],
      'argv': arguments['arguments'],
      'workingDirectory': arguments['workingDirectory'],
      'timeoutSeconds': arguments['timeoutSeconds'],
      'terminalProcessState': hostData['termination'],
      'exitCode': hostData['exitCode'],
      'stdoutTruncated': hostData['stdoutTruncated'],
      'stderrTruncated': hostData['stderrTruncated'],
      'toolOutcomeDisposition': outcome?.disposition.name,
      'effectCertainty': outcome?.effectCertainty.name,
    },
    _ => <String, Object?>{'failureCode': hostData['code']},
  };
}

int? _sumKnown(Iterable<int?> values) {
  var found = false;
  var total = 0;
  for (final int? value in values) {
    if (value == null) continue;
    found = true;
    total += value;
  }
  return found ? total : null;
}

List<String> _changedAreas(List<String> files) {
  final Set<String> areas = <String>{};
  for (final String file in files) {
    final List<String> parts = file.split('/');
    if (parts.length > 1 &&
        (parts.first == 'packages' || parts.first == 'plugins')) {
      areas.add('${parts[0]}/${parts[1]}');
    } else {
      areas.add(parts.first);
    }
  }
  final List<String> sorted = areas.toList()..sort();
  return sorted;
}

String _attemptMarkdown(Map<String, Object?> evidence) => evidence.entries
    .where((MapEntry<String, Object?> entry) => entry.value != null)
    .map(
      (MapEntry<String, Object?> entry) =>
          '${entry.key}=${jsonEncode(entry.value)}',
    )
    .join(', ');

String _proposalMarkdownArguments(
  String alias,
  Map<String, Object?> arguments,
) {
  final Map<String, Object?> concise = switch (alias) {
    'create_file' => <String, Object?>{
      'relativePath': arguments['relativePath'],
      'contentBytes': _utf8Size(arguments['content']),
    },
    'apply_patch' => <String, Object?>{
      'relativePath': arguments['relativePath'],
      'expectedRevision': arguments['expectedRevision'],
      'searchBytes': _utf8Size(arguments['search']),
      'replaceBytes': _utf8Size(arguments['replace']),
    },
    _ => _boundedArguments(arguments) as Map<String, Object?>,
  };
  return '`${jsonEncode(concise)}`';
}

int? _utf8Size(Object? value) =>
    value is String ? utf8.encode(value).length : null;

Object? _boundedArguments(Object? value) {
  if (value is String && value.length > 512) {
    return <String, Object?>{
      'omitted': true,
      'utf8Bytes': utf8.encode(value).length,
    };
  }
  if (value is List<Object?>) {
    return value.map(_boundedArguments).toList(growable: false);
  }
  if (value is Map<String, Object?>) {
    return <String, Object?>{
      for (final MapEntry<String, Object?> entry in value.entries)
        entry.key: _boundedArguments(entry.value),
    };
  }
  return value;
}

String _boundedMarkdownText(String value) {
  const int maximumCharacters = 12000;
  if (value.length <= maximumCharacters) return value;
  return '${value.substring(0, maximumCharacters)}\n\n'
      '[truncated ${value.length - maximumCharacters} characters]';
}

String _markdownValue(Object? value) {
  if (value == null) return 'none';
  return jsonEncode(value).replaceAll('|', r'\|').replaceAll('\n', ' ');
}

Future<void> _writeJson(File file, Object? value) => file.writeAsString(
  '${const JsonEncoder.withIndent('  ').convert(_sortedJson(value))}\n',
);

Object? _sortedJson(Object? value) {
  if (value is Map<String, Object?>) {
    final SplayTreeMap<String, Object?> sorted =
        SplayTreeMap<String, Object?>();
    for (final MapEntry<String, Object?> entry in value.entries) {
      sorted[entry.key] = _sortedJson(entry.value);
    }
    return sorted;
  }
  if (value is List<Object?>) return value.map(_sortedJson).toList();
  return value;
}

Future<_GitResult> _git(Directory directory, List<String> arguments) async {
  try {
    final ProcessResult result = await Process.run(
      'git',
      arguments,
      workingDirectory: directory.path,
      runInShell: Platform.isWindows,
    );
    return _GitResult(
      exitCode: result.exitCode,
      stdout: result.stdout.toString(),
      stderr: result.stderr.toString(),
    );
  } on Object catch (error) {
    return _GitResult(exitCode: -1, stdout: '', stderr: '$error\n');
  }
}

List<String> _nulValues(
  _GitResult result, {
  required String label,
  required List<String> arguments,
  required List<DevelopmentSelfHostingGitEvidenceFailure> failures,
}) {
  if (result.stdout.isEmpty) return const <String>[];
  if (!result.stdout.endsWith('\u0000')) {
    failures.add(
      DevelopmentSelfHostingGitEvidenceFailure(
        label: '$label encoding',
        arguments: List<String>.unmodifiable(arguments),
        exitCode: result.exitCode,
        message: 'Git pathname output was not NUL terminated.',
      ),
    );
  }
  final List<String> values = result.stdout.split('\u0000');
  if (values.isNotEmpty && values.last.isEmpty) values.removeLast();
  return values;
}

bool _expectedTrackedDiffCheck(_GitResult result) =>
    result.exitCode == 0 ||
    (result.exitCode == 2 && result.stderr.isEmpty && result.stdout.isNotEmpty);

bool _expectedNoIndexDifference(_GitResult result) =>
    result.exitCode == 0 ||
    (result.exitCode == 1 && result.stderr.isEmpty && result.stdout.isNotEmpty);

bool _expectedNoIndexDiffCheck(_GitResult result) =>
    result.exitCode == 0 ||
    (result.exitCode == 1 && result.stderr.isEmpty) ||
    (result.exitCode == 3 && result.stderr.isEmpty && result.stdout.isNotEmpty);

String _gitFailureMessage(_GitResult result) {
  final String diagnostic = result.stderr.trim().isNotEmpty
      ? result.stderr.trim()
      : result.stdout.trim();
  return diagnostic.isEmpty
      ? 'Git exited ${result.exitCode} without diagnostics.'
      : diagnostic;
}

final class _GitResult {
  const _GitResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get success => exitCode == 0;

  String get rendered {
    final StringBuffer output = StringBuffer();
    if (stdout.isNotEmpty) output.write(stdout);
    if (stderr.isNotEmpty) {
      if (output.isNotEmpty && !output.toString().endsWith('\n')) {
        output.writeln();
      }
      output.write(stderr);
    }
    if (!success) {
      if (output.isNotEmpty && !output.toString().endsWith('\n')) {
        output.writeln();
      }
      output.writeln('[git exit code: $exitCode]');
    }
    return output.toString();
  }
}

String _expectedNoIndexDiff(_GitResult result) {
  if (result.exitCode == 0 || result.exitCode == 1) {
    return '${result.stdout}${result.stderr}';
  }
  return result.rendered;
}

final class _Proposal {
  const _Proposal({
    required this.sequence,
    required this.modelInvocationId,
    required this.output,
  });

  final int sequence;
  final ModelInvocationId modelInvocationId;
  final ModelToolProposalOutput output;
}

final class _ModelTerminal {
  const _ModelTerminal({
    required this.invocationId,
    required this.terminalState,
    required this.effectiveModel,
    required this.usage,
    required this.failure,
  });

  final ModelInvocationId invocationId;
  final String terminalState;
  final String? effectiveModel;
  final ModelUsage? usage;
  final Object? failure;
}
