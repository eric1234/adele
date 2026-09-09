import 'dart:convert';
import 'dart:io';

import 'package:adele_desktop/development/agent/development_self_hosting.dart';
import 'package:adele_desktop/development/agent/development_self_hosting_report.dart';
import 'package:adele_desktop/development/agent/development_self_hosting_runner.dart';
import 'package:adele_desktop/development/agent/simple_tool_loop_strategy.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses explicit runner inputs and rejects a nonpositive ceiling', () {
    final DevelopmentSelfHostingOptions options =
        DevelopmentSelfHostingOptions.parse(<String>[
          '--prompt-file',
          'prompt.md',
          '--instructions-file=instructions.md',
          '--task-title',
          'Focused task',
          '--max-model-invocations',
          '40',
          '--output-dir',
          'output',
          '--profile',
          'api-key',
        ]);

    expect(options.taskTitle, 'Focused task');
    expect(options.maxModelInvocations, 40);
    expect(options.profile, DevelopmentSelfHostingProfile.apiKey);
    expect(options.promptFile.isAbsolute, isTrue);
    expect(
      () => DevelopmentSelfHostingOptions.parse(<String>[
        '--prompt-file=p',
        '--instructions-file=i',
        '--task-title=t',
        '--max-model-invocations=0',
        '--output-dir=o',
      ]),
      throwsA(isA<DevelopmentSelfHostingUsageException>()),
    );
  });

  test(
    'maintained ChatGPT profile honors model configuration and fallback',
    () {
      final DevelopmentSelfHostingProviderConfiguration fallback =
          DevelopmentSelfHostingProviderConfiguration.fromEnvironment(
            DevelopmentSelfHostingProfile.chatgpt,
            environment: const <String, String>{
              'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE':
                  '/private/credential.json',
            },
          );
      final DevelopmentSelfHostingProviderConfiguration configured =
          DevelopmentSelfHostingProviderConfiguration.fromEnvironment(
            DevelopmentSelfHostingProfile.chatgpt,
            environment: const <String, String>{
              'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE':
                  '/private/credential.json',
              'ADELE_OPENAI_CHATGPT_TEST_MODEL': 'configured-model',
            },
          );

      expect(fallback.providerId, developmentSelfHostingChatGptProviderId);
      expect(fallback.configuredContext, 'chatgpt-experimental');
      expect(fallback.selectedModel, developmentSelfHostingChatGptDefaultModel);
      expect(configured.selectedModel, 'configured-model');
    },
  );

  test(
    'successful and invocation-limited Runs have explicit exit semantics',
    () async {
      final DevelopmentSelfHostingRunResult success =
          await executeDevelopmentSelfHostingRun(
            identity: 'success',
            sessionId: SessionId('session-success'),
            prompt: 'Complete.',
            instructions: 'Respond.',
            model: _FinalModel(),
            catalog: ToolCatalog(),
            maxModelInvocations: 1,
          );
      final DevelopmentSelfHostingRunResult limited =
          await executeDevelopmentSelfHostingRun(
            identity: 'limited',
            sessionId: SessionId('session-limited'),
            prompt: 'Loop.',
            instructions: 'Use a tool.',
            model: _AlwaysProposalModel(),
            catalog: _catalog(<String>['read_file']),
            maxModelInvocations: 1,
          );

      expect(success.run.state, RunState.completed);
      expect(success.exitCode, 0);
      expect(limited.run.state, RunState.failed);
      expect(limited.exitCode, 1);
      expect(limited.run.failure, isA<ModelInvocationLimitExceeded>());
      final Map<String, Object?> summary = developmentSelfHostingSummaryJson(
        result: limited,
        selectedModel: 'fake-model',
        git: _emptyGitEvidence,
      );
      final Map<String, Object?> tools =
          summary['tools']! as Map<String, Object?>;
      final List<Object?> unprepared =
          tools['unpreparedProposals']! as List<Object?>;
      expect(unprepared, hasLength(1));
      expect(unprepared.single, isNot(contains('reason')));
      expect(
        (unprepared.single! as Map<String, Object?>)['alias'],
        'read_file',
      );
    },
  );

  test('ChatGPT requires matching reported effective models', () async {
    final DevelopmentSelfHostingRunResult matching =
        await executeDevelopmentSelfHostingRun(
          identity: 'matching-model',
          sessionId: SessionId('session-matching-model'),
          prompt: 'Complete.',
          instructions: 'Respond.',
          model: _FinalModel(),
          catalog: ToolCatalog(),
          maxModelInvocations: 1,
        );
    final DevelopmentSelfHostingRunResult substituted =
        await executeDevelopmentSelfHostingRun(
          identity: 'substituted-model',
          sessionId: SessionId('session-substituted-model'),
          prompt: 'Complete.',
          instructions: 'Respond.',
          model: _FinalModel(effectiveModel: 'substituted-model'),
          catalog: ToolCatalog(),
          maxModelInvocations: 1,
        );
    final DevelopmentSelfHostingRunResult unreported =
        await executeDevelopmentSelfHostingRun(
          identity: 'unreported-model',
          sessionId: SessionId('session-unreported-model'),
          prompt: 'Complete.',
          instructions: 'Respond.',
          model: const _FinalModel(effectiveModel: null),
          catalog: ToolCatalog(),
          maxModelInvocations: 1,
        );
    final DevelopmentSelfHostingRunResult noCompletedSettlement =
        await executeDevelopmentSelfHostingRun(
          identity: 'refused-model',
          sessionId: SessionId('session-refused-model'),
          prompt: 'Complete.',
          instructions: 'Respond.',
          model: const _RefusedModel(),
          catalog: ToolCatalog(),
          maxModelInvocations: 1,
        );

    expect(
      validateDevelopmentSelfHostingEffectiveModels(
        profile: DevelopmentSelfHostingProfile.chatgpt,
        selectedModel: 'fake-model',
        result: matching,
      ),
      isNull,
    );
    expect(
      validateDevelopmentSelfHostingEffectiveModels(
        profile: DevelopmentSelfHostingProfile.chatgpt,
        selectedModel: 'fake-model',
        result: substituted,
      ),
      isA<DevelopmentSelfHostingEffectiveModelException>(),
    );
    expect(noCompletedSettlement.run.state, RunState.completed);
    expect(
      validateDevelopmentSelfHostingEffectiveModels(
        profile: DevelopmentSelfHostingProfile.chatgpt,
        selectedModel: 'fake-model',
        result: noCompletedSettlement,
      ),
      isA<DevelopmentSelfHostingEffectiveModelException>(),
    );
    expect(
      validateDevelopmentSelfHostingEffectiveModels(
        profile: DevelopmentSelfHostingProfile.chatgpt,
        selectedModel: 'fake-model',
        result: unreported,
      ),
      isA<DevelopmentSelfHostingEffectiveModelException>(),
    );
    expect(
      validateDevelopmentSelfHostingEffectiveModels(
        profile: DevelopmentSelfHostingProfile.apiKey,
        selectedModel: 'fake-model',
        result: substituted,
      ),
      isNull,
    );
  });

  test(
    'reports deterministic model, tool, revision, command, and Git evidence',
    () async {
      final Directory container = await Directory.systemTemp.createTemp(
        'adele-self-hosting-report-test-',
      );
      addTearDown(() async {
        if (await container.exists()) await container.delete(recursive: true);
      });
      final _GitFixture git = await _createGitFixture(container);
      final DevelopmentSelfHostingRunResult result =
          await executeDevelopmentSelfHostingRun(
            identity: 'evidence',
            sessionId: SessionId('session-evidence'),
            prompt: 'Exercise the tools.',
            instructions: 'Use deterministic fixtures.',
            model: _EvidenceModel(),
            catalog: _catalog(developmentSelfHostingToolAliases),
            maxModelInvocations: 10,
          );
      expect(result.exitCode, 0);

      final DevelopmentSelfHostingGitEvidence gitEvidence =
          await collectDevelopmentSelfHostingGitEvidence(
            launchingRepository: git.launching,
            projectSource: git.project,
            taskWorktree: git.task,
            taskBaseline: git.startingHead,
          );
      final Map<String, Object?> summary = developmentSelfHostingSummaryJson(
        result: result,
        selectedModel: 'fake-model',
        git: gitEvidence,
        taskBaseline: git.startingHead,
      );
      final Map<String, Object?> run = summary['run']! as Map<String, Object?>;
      final Map<String, Object?> aggregates =
          summary['aggregates']! as Map<String, Object?>;
      final Map<String, Object?> usage =
          summary['usageTotals']! as Map<String, Object?>;
      final Map<String, Object?> tools =
          summary['tools']! as Map<String, Object?>;
      final Map<String, Object?> aliases =
          tools['aliases']! as Map<String, Object?>;
      final List<Object?> attempts = tools['attempts']! as List<Object?>;

      expect(run['completedModelInvocations'], 8);
      expect(run['effectiveModelSequence'], everyElement('fake-model'));
      expect(run['hasFinalAssistantResponse'], isTrue);
      expect(aggregates['totalBytesRead'], 12);
      expect(aggregates['failedToolCount'], 1);
      expect(aggregates['revisionConflictCount'], 1);
      expect(aggregates['commandCount'], 1);
      expect(usage['inputTokens'], 3600);
      expect(usage['inputTotalComplete'], isTrue);
      expect(usage['reportedInputInvocations'], 8);
      expect(
        (aliases['apply_patch']! as Map<String, Object?>)['proposalCount'],
        2,
      );
      expect(
        _attemptEvidence(attempts, 'search'),
        containsPair('matchCount', 2),
      );
      expect(
        _attemptEvidence(attempts, 'read_file'),
        containsPair('revision', 'r1'),
      );
      expect(
        _attemptEvidence(attempts, 'apply_patch', last: true),
        containsPair('resultingRevision', 'r2'),
      );
      expect(
        _attemptEvidence(attempts, 'create_file'),
        allOf(
          containsPair('relativePath', 'lib/new.dart'),
          containsPair('resultingRevision', 'c1'),
        ),
      );
      expect(
        _attemptEvidence(attempts, 'delete_file'),
        allOf(
          containsPair('relativePath', 'lib/old.dart'),
          containsPair('expectedRevision', 'r0'),
        ),
      );
      expect(
        _attemptEvidence(attempts, 'run_command'),
        allOf(
          containsPair('program', 'git'),
          containsPair('argv', <String>['diff', '--check']),
          containsPair('terminalProcessState', 'exited'),
          containsPair('exitCode', 0),
          containsPair('stdoutTruncated', false),
        ),
      );
      expect(gitEvidence.changedFiles, <String>['fixture.txt']);
      expect(gitEvidence.collectionSucceeded, isTrue);
      expect(gitEvidence.launchingClean, isTrue);
      expect(gitEvidence.projectClean, isTrue);
      expect(
        await File('${git.launching.path}/fixture.txt').readAsString(),
        'base\n',
      );
      expect(
        await File('${git.project.path}/fixture.txt').readAsString(),
        'base\n',
      );
      expect(
        await File('${git.task.path}/fixture.txt').readAsString(),
        'task\n',
      );
      expect(git.launching.path, isNot(git.project.path));
      expect(git.project.path, isNot(git.task.path));

      final Directory runDirectory = Directory('${container.path}/evidence');
      await File('${runDirectory.path}/runner.log')
          .create(recursive: true)
          .then((File file) => file.writeAsString('fixture runner log\n'));
      const String credentialValue = 'credential-value-must-not-appear';
      final DevelopmentSelfHostingProviderConfiguration providerConfiguration =
          DevelopmentSelfHostingProviderConfiguration.fromEnvironment(
            DevelopmentSelfHostingProfile.chatgpt,
            environment: const <String, String>{
              'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': credentialValue,
              'ADELE_OPENAI_CHATGPT_TEST_MODEL': 'fake-model',
            },
          );
      final DevelopmentSelfHostingEvidenceContext context =
          DevelopmentSelfHostingEvidenceContext(
            runDirectory: runDirectory,
            launchingRepository: git.launching,
            sourceHead: git.startingHead,
            projectSource: git.project,
            taskWorktree: git.task,
            taskTitle: 'Evidence task',
            taskBranch: 'fixture-task',
            taskBaseline: git.startingHead,
            projectId: 'project-evidence',
            taskId: 'task-evidence',
            environmentId: 'environment-evidence',
            sessionId: 'session-evidence',
            profile: providerConfiguration.profile.cliName,
            providerId: providerConfiguration.providerId,
            configuredContext: providerConfiguration.configuredContext,
            selectedModel: providerConfiguration.selectedModel,
            maxModelInvocations: 10,
            promptFileHash: 'prompt-hash',
            instructionsFileHash: 'instructions-hash',
            startedAt: DateTime.utc(2026, 9, 9),
            phaseDurations: const <String, int?>{
              'sourceReconciliationPreflight': 1,
              'artifactCompilation': 2,
              'projectClone': 3,
              'lifecycleTaskEnvironmentSetup': 4,
              'providerActivation': 5,
              'adeleRun': 6,
              'evidenceReportGeneration': 0,
              'teardown': 7,
            },
            runnerFailure: null,
          );
      final Map<String, Object?> manifest =
          await const DevelopmentSelfHostingEvidenceWriter().write(
            context: context,
            result: result,
            git: gitEvidence,
          );

      expect(
        await runDirectory
            .list()
            .map((FileSystemEntity value) => value.path.split('/').last)
            .toSet(),
        containsAll(<String>{
          'manifest.json',
          'journal.json',
          'summary.json',
          'summary.md',
          'runner.log',
          'git',
        }),
      );
      for (final String name in <String>[
        'status.txt',
        'diff.patch',
        'diff-stat.txt',
        'diff-check.txt',
        'changed-files.txt',
        'facts.json',
      ]) {
        expect(await File('${runDirectory.path}/git/$name').exists(), isTrue);
      }
      expect(
        manifest['schemaVersion'],
        developmentSelfHostingReportSchemaVersion,
      );
      expect(
        (manifest['terminal']! as Map<String, Object?>)['runState'],
        'completed',
      );
      final Map<String, Object?> provenance =
          manifest['provenance']! as Map<String, Object?>;
      final Map<String, Object?> timing =
          manifest['timing']! as Map<String, Object?>;
      expect(provenance['startingSourceSha'], git.startingHead);
      expect(provenance['taskTitle'], 'Evidence task');
      expect(provenance['projectId'], 'project-evidence');
      expect(provenance['taskId'], 'task-evidence');
      expect(provenance['environmentId'], 'environment-evidence');
      expect(provenance['sessionId'], 'session-evidence');
      expect(provenance['runId'], 'run-evidence');
      expect(provenance['maxModelInvocations'], 10);
      expect(
        (timing['phaseDurationsMilliseconds']! as Map<String, Object?>).keys,
        containsAll(<String>{
          'sourceReconciliationPreflight',
          'artifactCompilation',
          'projectClone',
          'lifecycleTaskEnvironmentSetup',
          'providerActivation',
          'adeleRun',
          'evidenceReportGeneration',
          'teardown',
        }),
      );
      final String manifestText = await File(
        '${runDirectory.path}/manifest.json',
      ).readAsString();
      expect(manifestText, isNot(contains(credentialValue)));
      expect(manifestText, isNot(contains('/private/credential.json')));
      expect(
        await File('${runDirectory.path}/summary.md').readAsString(),
        allOf(contains('## Model Usage'), isNot(contains('whole file text'))),
      );
      final Map<String, Object?> journal =
          jsonDecode(
                await File('${runDirectory.path}/journal.json').readAsString(),
              )
              as Map<String, Object?>;
      expect(
        journal['schemaVersion'],
        developmentSelfHostingReportSchemaVersion,
      );
      expect(journal['records'], isNotEmpty);
    },
  );

  test(
    'failed Run still writes predictable evidence and failure manifest',
    () async {
      final Directory container = await Directory.systemTemp.createTemp(
        'adele-self-hosting-failure-test-',
      );
      addTearDown(() async {
        if (await container.exists()) await container.delete(recursive: true);
      });
      final _GitFixture git = await _createGitFixture(container);
      final DevelopmentSelfHostingRunResult failed =
          await executeDevelopmentSelfHostingRun(
            identity: 'failed-evidence',
            sessionId: SessionId('session-failed-evidence'),
            prompt: 'Keep proposing.',
            instructions: 'Exercise the ceiling.',
            model: _AlwaysProposalModel(),
            catalog: _catalog(<String>['read_file']),
            maxModelInvocations: 1,
          );
      final DevelopmentSelfHostingGitEvidence gitEvidence =
          await collectDevelopmentSelfHostingGitEvidence(
            launchingRepository: git.launching,
            projectSource: git.project,
            taskWorktree: git.task,
            taskBaseline: git.startingHead,
          );
      final Directory runDirectory = Directory('${container.path}/failed');
      final Map<String, Object?> manifest =
          await const DevelopmentSelfHostingEvidenceWriter().write(
            context: DevelopmentSelfHostingEvidenceContext(
              runDirectory: runDirectory,
              launchingRepository: git.launching,
              sourceHead: git.startingHead,
              projectSource: git.project,
              taskWorktree: git.task,
              taskTitle: 'Failed task',
              taskBranch: 'fixture-task',
              taskBaseline: git.startingHead,
              projectId: 'project-failed',
              taskId: 'task-failed',
              environmentId: 'environment-failed',
              sessionId: 'session-failed-evidence',
              profile: 'chatgpt',
              providerId: developmentSelfHostingChatGptProviderId,
              configuredContext: 'chatgpt-experimental',
              selectedModel: 'fake-model',
              maxModelInvocations: 1,
              promptFileHash: 'prompt-hash',
              instructionsFileHash: 'instructions-hash',
              startedAt: DateTime.utc(2026, 9, 9),
              phaseDurations: const <String, int?>{},
              runnerFailure: failed.run.failure,
            ),
            result: failed,
            git: gitEvidence,
          );

      expect(failed.exitCode, 1);
      expect(
        (manifest['terminal']! as Map<String, Object?>)['runState'],
        'failed',
      );
      expect(
        ((manifest['terminal']! as Map<String, Object?>)['failure']!
            as Map<String, Object?>)['type'],
        'ModelInvocationLimitExceeded',
      );
      expect(await File('${runDirectory.path}/journal.json').exists(), isTrue);
      expect(
        await File('${runDirectory.path}/git/diff.patch').exists(),
        isTrue,
      );
    },
  );

  test('Git path evidence preserves unusual untracked filenames', () async {
    final Directory container = await Directory.systemTemp.createTemp(
      'adele-self-hosting-untracked-test-',
    );
    addTearDown(() async {
      if (await container.exists()) await container.delete(recursive: true);
    });
    final _GitFixture git = await _createGitFixture(container);
    const String unusualPath = 'café "quoted" \\ tab\tline\nbreak.dart';
    await File(
      '${git.task.path}/$unusualPath',
    ).writeAsString('unusual path payload with trailing space \n');

    final DevelopmentSelfHostingGitEvidence evidence =
        await collectDevelopmentSelfHostingGitEvidence(
          launchingRepository: git.launching,
          projectSource: git.project,
          taskWorktree: git.task,
          taskBaseline: git.startingHead,
        );

    expect(evidence.collectionSucceeded, isTrue);
    expect(evidence.changedFiles, contains(unusualPath));
    expect(evidence.taskDiff, contains('unusual path payload'));
    expect(evidence.taskDiffCheck, contains('trailing whitespace'));
    expect(evidence.taskDiffCheckExitCode, isNot(0));
  });

  test('missing Task Git repository fails required evidence', () async {
    final Directory container = await Directory.systemTemp.createTemp(
      'adele-self-hosting-missing-task-git-test-',
    );
    addTearDown(() async {
      if (await container.exists()) await container.delete(recursive: true);
    });
    final _GitFixture git = await _createGitFixture(container);
    await Directory('${git.task.path}/.git').delete(recursive: true);
    final DevelopmentSelfHostingRunResult run =
        await executeDevelopmentSelfHostingRun(
          identity: 'missing-task-git',
          sessionId: SessionId('session-missing-task-git'),
          prompt: 'Complete.',
          instructions: 'Respond.',
          model: _FinalModel(),
          catalog: ToolCatalog(),
          maxModelInvocations: 1,
        );

    final DevelopmentSelfHostingGitEvidence evidence =
        await collectDevelopmentSelfHostingGitEvidence(
          launchingRepository: git.launching,
          projectSource: git.project,
          taskWorktree: git.task,
          taskBaseline: git.startingHead,
        );
    final Directory runDirectory = Directory('${container.path}/evidence');
    final DevelopmentSelfHostingRunnerResult runnerResult =
        DevelopmentSelfHostingRunnerResult(
          runDirectory: runDirectory,
          projectSource: git.project,
          taskWorktree: git.task,
          runState: run.run.state,
          failure: evidence.failure,
        );
    final Map<String, Object?> manifest =
        await const DevelopmentSelfHostingEvidenceWriter().write(
          context: _evidenceContext(
            runDirectory: runDirectory,
            git: git,
            runnerFailure: evidence.failure,
          ),
          result: run,
          git: evidence,
        );

    expect(run.run.state, RunState.completed);
    expect(evidence.collectionSucceeded, isFalse);
    expect(evidence.failure, isNotNull);
    expect(runnerResult.exitCode, 1);
    expect(
      (manifest['terminal']! as Map<String, Object?>)['failure'],
      containsPair('type', 'DevelopmentSelfHostingGitEvidenceException'),
    );
    final Map<String, Object?> summary =
        jsonDecode(
              await File('${runDirectory.path}/summary.json').readAsString(),
            )
            as Map<String, Object?>;
    final Map<String, Object?> summaryGit =
        summary['git']! as Map<String, Object?>;
    expect(
      (summaryGit['collection']! as Map<String, Object?>)['succeeded'],
      isFalse,
    );
  });

  test('output root must be outside the checkout or ignored', () async {
    final Directory container = await Directory.systemTemp.createTemp(
      'adele-self-hosting-output-root-test-',
    );
    addTearDown(() async {
      if (await container.exists()) await container.delete(recursive: true);
    });
    final _GitFixture git = await _createGitFixture(container);

    await validateDevelopmentSelfHostingOutputRoot(
      launchingRepository: git.launching,
      outputRoot: Directory('${git.launching.path}/.ignored/self-hosting'),
    );
    await validateDevelopmentSelfHostingOutputRoot(
      launchingRepository: git.launching,
      outputRoot: Directory('${container.path}/outside-output'),
    );
    expect(
      () => validateDevelopmentSelfHostingOutputRoot(
        launchingRepository: git.launching,
        outputRoot: Directory('${git.launching.path}/visible-output'),
      ),
      throwsA(isA<DevelopmentSelfHostingOutputRootException>()),
    );
    expect(
      () => validateDevelopmentSelfHostingOutputRoot(
        launchingRepository: git.launching,
        outputRoot: Directory(
          '${git.launching.path}/.ignored/../visible-output',
        ),
      ),
      throwsA(isA<DevelopmentSelfHostingOutputRootException>()),
    );
  });

  test('concurrent run-directory claims are distinct', () async {
    final Directory outputRoot = await Directory.systemTemp.createTemp(
      'adele-self-hosting-directory-claim-test-',
    );
    addTearDown(() async {
      if (await outputRoot.exists()) await outputRoot.delete(recursive: true);
    });
    final DateTime startedAt = DateTime.utc(2026, 9, 9);

    final List<Directory> claimed = await Future.wait(<Future<Directory>>[
      for (var index = 0; index < 8; index++)
        claimDevelopmentSelfHostingRunDirectory(
          outputRoot: outputRoot,
          startedAt: startedAt,
          sourceHead: '0123456789abcdef',
        ),
    ]);

    expect(claimed.map((Directory value) => value.path).toSet(), hasLength(8));
    expect(
      await Future.wait(claimed.map((Directory value) => value.exists())),
      everyElement(isTrue),
    );
  });

  test('setup failure is represented in deterministic summary', () {
    final Map<String, Object?> summary = developmentSelfHostingSummaryJson(
      result: null,
      selectedModel: null,
      git: _emptyGitEvidence,
      runnerFailure: StateError('setup failed'),
    );

    final Map<String, Object?> run = summary['run']! as Map<String, Object?>;
    expect(run['terminalState'], isNull);
    expect(
      run['failure'],
      allOf(
        containsPair('type', 'StateError'),
        containsPair('message', contains('setup failed')),
      ),
    );
    expect(
      developmentSelfHostingSummaryMarkdown(summary),
      contains('setup failed'),
    );
  });
}

Map<String, Object?> _attemptEvidence(
  List<Object?> attempts,
  String alias, {
  bool last = false,
}) {
  final List<Map<String, Object?>> matching = attempts
      .whereType<Map<String, Object?>>()
      .where((Map<String, Object?> value) => value['alias'] == alias)
      .toList(growable: false);
  final Map<String, Object?> attempt = last ? matching.last : matching.first;
  return attempt['evidence']! as Map<String, Object?>;
}

ToolCatalog _catalog(Iterable<String> aliases) {
  final ToolCatalog catalog = ToolCatalog();
  for (final String alias in aliases) {
    catalog.register(
      ToolRegistration(
        definition: ToolDefinition(
          id: ToolId('dev.adele.test.$alias'),
          description: 'Fixture $alias tool.',
        ),
        modelDefinition: ModelToolDefinition(
          alias: alias,
          description: 'Fixture $alias tool.',
          argumentsSchema: const <String, Object?>{'type': 'object'},
        ),
        executable: _FixtureTool(alias),
      ),
    );
  }
  return catalog;
}

final class _FinalModel implements ModelPort {
  const _FinalModel({this.effectiveModel = 'fake-model'});

  final String? effectiveModel;

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    yield ModelOutputItemCompleted(
      invocationId: request.invocationId,
      item: ModelTextOutput('Complete.'),
    );
    yield ModelInvocationSettledEvent(
      invocationId: request.invocationId,
      metadata: ModelTerminalMetadata(effectiveModel: effectiveModel),
    );
  }
}

final class _AlwaysProposalModel implements ModelPort {
  var _next = 1;

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    yield ModelOutputItemCompleted(
      invocationId: request.invocationId,
      item: ModelToolProposalOutput(
        ProviderToolProposal(
          providerCallId: 'call-${_next++}',
          alias: 'read_file',
          arguments: const <String, Object?>{'relativePath': 'fixture.txt'},
        ),
      ),
    );
    yield ModelInvocationSettledEvent(
      invocationId: request.invocationId,
      metadata: ModelTerminalMetadata(effectiveModel: 'fake-model'),
    );
  }
}

final class _RefusedModel implements ModelPort {
  const _RefusedModel();

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    yield ModelOutputItemCompleted(
      invocationId: request.invocationId,
      item: ModelTextOutput('Refused.'),
    );
    yield ModelInvocationSettledEvent(
      invocationId: request.invocationId,
      settlement: ModelSettlement.refused,
      metadata: ModelTerminalMetadata(effectiveModel: 'fake-model'),
    );
  }
}

final class _EvidenceModel implements ModelPort {
  static const List<String?> _turns = <String?>[
    'search',
    'read_file',
    'apply_patch',
    'apply_patch',
    'create_file',
    'delete_file',
    'run_command',
    null,
  ];

  var _invocations = 0;

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    final int invocation = ++_invocations;
    final String? alias = _turns[invocation - 1];
    if (alias == null) {
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelTextOutput('All deterministic fixture work completed.'),
      );
    } else {
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelToolProposalOutput(
          ProviderToolProposal(
            providerCallId: 'call-$invocation',
            alias: alias,
            arguments: _arguments(alias),
          ),
        ),
      );
    }
    yield ModelInvocationSettledEvent(
      invocationId: request.invocationId,
      metadata: ModelTerminalMetadata(
        effectiveModel: 'fake-model',
        usage: ModelUsage(
          inputTokens: invocation * 100,
          outputTokens: 10,
          cacheReadTokens: 5,
          providerDetails: <String, Object?>{
            'totalTokens': invocation * 100 + 10,
          },
        ),
      ),
    );
  }

  Map<String, Object?> _arguments(String alias) => switch (alias) {
    'search' => <String, Object?>{'query': 'needle'},
    'read_file' => <String, Object?>{'relativePath': 'lib/a.dart'},
    'apply_patch' => <String, Object?>{
      'relativePath': 'lib/a.dart',
      'expectedRevision': 'r1',
      'search': 'old',
      'replace': 'new',
    },
    'create_file' => <String, Object?>{
      'relativePath': 'lib/new.dart',
      'content': 'new',
    },
    'delete_file' => <String, Object?>{
      'relativePath': 'lib/old.dart',
      'expectedRevision': 'r0',
    },
    'run_command' => <String, Object?>{
      'program': 'git',
      'arguments': <Object?>['diff', '--check'],
      'workingDirectory': '',
      'timeoutSeconds': 30,
    },
    _ => throw StateError('Unsupported fixture alias: $alias'),
  };
}

final class _FixtureTool implements ToolExecutable {
  _FixtureTool(this.alias);

  final String alias;
  var _executions = 0;

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async => EffectDescription(
    effects: <ToolEffect>[
      alias == 'run_command'
          ? ToolEffect.processExecution
          : alias == 'read_file' || alias == 'search'
          ? ToolEffect.sourceRead
          : ToolEffect.sourceMutation,
    ],
    targets: <EffectTarget>[
      EffectTarget(uri: Uri.parse('adele-environment:/environment-fixture/')),
    ],
    summary: 'Exercise $alias.',
  );

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    _executions++;
    if (alias == 'apply_patch' && _executions == 1) {
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.failure,
          failureKind: ToolFailureKind.domain,
          effectCertainty: EffectCertainty.knownNotOccurred,
          modelContent: 'Revision conflict.',
          hostData: const <String, Object?>{
            'relativePath': 'lib/a.dart',
            'code': 'revision_conflict',
          },
        ),
      );
      return;
    }
    yield ToolExecutionTerminal(
      ToolOutcome(
        disposition: ToolOutcomeDisposition.success,
        effectCertainty: EffectCertainty.knownOccurred,
        modelContent: 'Fixture $alias completed.',
        hostData: _hostData(alias),
      ),
    );
  }

  @override
  CanonicalToolArguments validateAndNormalize(
    Map<String, Object?> proposedArguments,
  ) => CanonicalToolArguments(proposedArguments);

  @override
  void validateBinding() {}

  Map<String, Object?> _hostData(String alias) => switch (alias) {
    'search' => <String, Object?>{
      'query': 'needle',
      'matches': <Object?>[
        <String, Object?>{'relativePath': 'lib/a.dart', 'lineNumber': 1},
        <String, Object?>{'relativePath': 'lib/b.dart', 'lineNumber': 2},
      ],
      'incomplete': false,
      'truncated': true,
    },
    'read_file' => <String, Object?>{
      'relativePath': 'lib/a.dart',
      'sizeBytes': 12,
      'revision': 'r1',
      'text': 'whole file text',
    },
    'apply_patch' => <String, Object?>{
      'relativePath': 'lib/a.dart',
      'newRevision': 'r2',
    },
    'create_file' => <String, Object?>{
      'relativePath': 'lib/new.dart',
      'revision': 'c1',
    },
    'delete_file' => <String, Object?>{'relativePath': 'lib/old.dart'},
    'run_command' => <String, Object?>{
      'program': 'git',
      'arguments': <Object?>['diff', '--check'],
      'workingDirectory': '',
      'timeoutSeconds': 30,
      'termination': 'exited',
      'exitCode': 0,
      'stdout': '',
      'stderr': '',
      'stdoutTruncated': false,
      'stderrTruncated': false,
    },
    _ => const <String, Object?>{},
  };
}

Future<_GitFixture> _createGitFixture(Directory container) async {
  final Directory launching = Directory('${container.path}/launching');
  await launching.create();
  await _git(launching, const <String>['init', '--quiet']);
  await _git(launching, const <String>['config', 'user.name', 'ADELE Test']);
  await _git(launching, const <String>[
    'config',
    'user.email',
    'adele@example.invalid',
  ]);
  await File('${launching.path}/fixture.txt').writeAsString('base\n');
  await File('${launching.path}/.gitignore').writeAsString('.ignored/\n');
  await _git(launching, const <String>['add', '.']);
  await _git(launching, const <String>['commit', '--quiet', '-m', 'Initial']);
  final String startingHead = await _git(launching, const <String>[
    'rev-parse',
    'HEAD',
  ]);
  final Directory project = Directory('${container.path}/project');
  await cloneDevelopmentSelfHostingProject(
    repository: launching,
    destination: project,
    sourceHead: startingHead,
  );
  final Directory task = Directory('${container.path}/task');
  await cloneDevelopmentSelfHostingProject(
    repository: project,
    destination: task,
    sourceHead: startingHead,
  );
  await File('${task.path}/fixture.txt').writeAsString('task\n');
  return _GitFixture(
    launching: launching,
    project: project,
    task: task,
    startingHead: startingHead,
  );
}

DevelopmentSelfHostingEvidenceContext _evidenceContext({
  required Directory runDirectory,
  required _GitFixture git,
  required Object? runnerFailure,
}) => DevelopmentSelfHostingEvidenceContext(
  runDirectory: runDirectory,
  launchingRepository: git.launching,
  sourceHead: git.startingHead,
  projectSource: git.project,
  taskWorktree: git.task,
  taskTitle: 'Fixture task',
  taskBranch: 'fixture-task',
  taskBaseline: git.startingHead,
  projectId: 'project-fixture',
  taskId: 'task-fixture',
  environmentId: 'environment-fixture',
  sessionId: 'session-fixture',
  profile: 'chatgpt',
  providerId: developmentSelfHostingChatGptProviderId,
  configuredContext: 'chatgpt-experimental',
  selectedModel: 'fake-model',
  maxModelInvocations: 1,
  promptFileHash: 'prompt-hash',
  instructionsFileHash: 'instructions-hash',
  startedAt: DateTime.utc(2026, 9, 9),
  phaseDurations: const <String, int?>{},
  runnerFailure: runnerFailure,
);

Future<String> _git(Directory directory, List<String> arguments) async {
  final ProcessResult result = await Process.run(
    'git',
    arguments,
    workingDirectory: directory.path,
  );
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return result.stdout.toString().trim();
}

const DevelopmentSelfHostingGitEvidence _emptyGitEvidence =
    DevelopmentSelfHostingGitEvidence(
      launchingHead: null,
      launchingStatus: '',
      projectHead: null,
      projectStatus: '',
      taskHead: null,
      taskStatus: '',
      taskDiff: '',
      taskDiffStat: '',
      taskDiffCheck: '',
      taskDiffCheckExitCode: 0,
      taskMergeBase: null,
      taskAheadBehind: null,
      changedFiles: <String>[],
    );

final class _GitFixture {
  const _GitFixture({
    required this.launching,
    required this.project,
    required this.task,
    required this.startingHead,
  });

  final Directory launching;
  final Directory project;
  final Directory task;
  final String startingHead;
}
