import 'dart:convert';
import 'dart:io';

import 'package:adele_desktop/development/agent/development_self_hosting.dart';
import 'package:adele_desktop/development/agent/development_self_hosting_report.dart';
import 'package:adele_desktop/development/agent/development_self_hosting_runner.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_test_topology.dart';

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

  test('runner-owned Git commands discard inherited Git behavior', () async {
    final Directory container = await Directory.systemTemp.createTemp(
      'adele-self-hosting-git-environment-test-',
    );
    addTearDown(() async {
      if (await container.exists()) await container.delete(recursive: true);
    });
    final _GitFixture git = await _createGitFixture(container);
    final Map<String, String> routedEnvironment = <String, String>{
      ...Platform.environment,
      'GIT_DIR': '${git.project.path}/.git',
      'GIT_WORK_TREE': git.project.path,
      'GIT_INDEX_FILE': '${git.project.path}/.git/index',
      'Git_Config_Count': '1',
      'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
    };
    final Map<String, String> sanitized =
        developmentSelfHostingGitProcessEnvironment(
          inheritedEnvironment: routedEnvironment,
        );
    final Directory hostileClone = Directory('${container.path}/hostile-clone');

    await cloneDevelopmentSelfHostingProject(
      repository: git.launching,
      destination: hostileClone,
      sourceHead: git.startingHead,
      inheritedGitEnvironment: routedEnvironment,
    );
    final DevelopmentSelfHostingGitEvidence routedEvidence =
        await collectDevelopmentSelfHostingGitEvidence(
          launchingRepository: git.launching,
          projectSource: git.project,
          taskWorktree: git.task,
          taskBaseline: git.startingHead,
          inheritedGitEnvironment: routedEnvironment,
        );
    final DevelopmentSelfHostingGitEvidence diffEvidence =
        await collectDevelopmentSelfHostingGitEvidence(
          launchingRepository: git.launching,
          projectSource: git.project,
          taskWorktree: git.task,
          taskBaseline: git.startingHead,
          inheritedGitEnvironment: <String, String>{
            ...Platform.environment,
            'GIT_EXTERNAL_DIFF': '/definitely/missing/adele-external-diff',
          },
        );

    expect(
      sanitized.keys.where(
        (String name) => name.toUpperCase().startsWith('GIT_'),
      ),
      isEmpty,
    );
    expect(sanitized['PATH'], routedEnvironment['PATH']);
    expect(
      await File('${hostileClone.path}/fixture.txt').readAsString(),
      'base\n',
    );
    expect(routedEvidence.collectionSucceeded, isTrue);
    expect(routedEvidence.taskDiff, contains('+task'));
    expect(diffEvidence.collectionSucceeded, isTrue);
    expect(diffEvidence.taskDiff, contains('+task'));
  });

  test(
    'six-tool host preflight mirrors Linux x64 setsid requirement',
    () async {
      await validateDevelopmentSelfHostingCommandHost(
        hostIsLinux: true,
        hostIsLinuxX64: true,
        isExecutable: (String path) async => path == '/bin/setsid',
      );

      for (final Future<void> Function() validation
          in <Future<void> Function()>[
            () => validateDevelopmentSelfHostingCommandHost(
              hostIsLinux: false,
              hostIsLinuxX64: false,
              isExecutable: (String _) async => true,
            ),
            () => validateDevelopmentSelfHostingCommandHost(
              hostIsLinux: true,
              hostIsLinuxX64: false,
              isExecutable: (String _) async => true,
            ),
            () => validateDevelopmentSelfHostingCommandHost(
              hostIsLinux: true,
              hostIsLinuxX64: true,
              isExecutable: (String _) async => false,
            ),
          ]) {
        await expectLater(
          validation(),
          throwsA(
            predicate<Object>(
              (Object error) => error.toString().contains(
                developmentSelfHostingHostRequirementMessage,
              ),
            ),
          ),
        );
      }
    },
  );

  test(
    'successful and invocation-limited Runs have explicit exit semantics',
    () async {
      final DevelopmentSelfHostingRunResult success = await _executeRun(
        identity: 'success',
        sessionId: SessionId('session-success'),
        prompt: 'Complete.',
        instructions: 'Respond.',
        model: _FinalModel(),
        catalog: ToolCatalog(),
        maxModelInvocations: 1,
      );
      final DevelopmentSelfHostingRunResult limited = await _executeRun(
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

  test('successive Runs retain Chat state for the canonical Session', () async {
    final ChatTestTopology topology = ChatTestTopology(
      SessionId('session-retained'),
    );
    addTearDown(topology.close);
    final List<SemanticModelRequest> requests = <SemanticModelRequest>[];
    final _FinalModel model = _FinalModel(requests: requests);
    final DevelopmentSelfHostingRunResult first =
        await executeDevelopmentSelfHostingRun(
          identity: 'retained-first',
          lifecycle: topology.lifecycle,
          sessions: topology.chat.sessions,
          sessionId: topology.session.id,
          prompt: 'First request.',
          instructions: 'First instructions.',
          model: model,
          catalog: ToolCatalog(),
          maxModelInvocations: 1,
        );
    final ChatSessionSnapshot firstSnapshot = first.session.snapshot();
    final DevelopmentSelfHostingRunResult second =
        await executeDevelopmentSelfHostingRun(
          identity: 'retained-second',
          lifecycle: topology.lifecycle,
          sessions: topology.chat.sessions,
          sessionId: topology.session.id,
          prompt: 'Second request.',
          instructions: 'Second instructions.',
          model: model,
          catalog: ToolCatalog(),
          maxModelInvocations: 2,
        );

    expect(first.run.state, RunState.completed);
    expect(second.run.state, RunState.completed);
    expect(first.run.id, isNot(second.run.id));
    expect(second.run.sessionId, topology.session.id);
    expect(second.session, same(first.session));
    expect(
      second.session,
      same(topology.chat.sessions.obtain(topology.session.id)),
    );
    expect(firstSnapshot.entries, hasLength(2));
    expect(
      second.session.snapshot().entries.map((entry) => entry.content),
      <String>['First request.', 'Complete.', 'Second request.', 'Complete.'],
    );
    expect(requests.map((request) => request.instructions), <String>[
      'First instructions.',
      'Second instructions.',
    ]);
    expect(
      requests.last.input.whereType<SemanticMessageInput>().map(
        (item) => item.content,
      ),
      <String>['First request.', 'Complete.', 'Second request.'],
    );
    expect(second.session.maxModelInvocations, 2);
    expect(
      topology.lifecycle.store.session(topology.session.id),
      same(topology.session),
    );
    expect(topology.session.strategyId, chatStrategyId);
  });

  test(
    'summary final response belongs to its Run, not the Session tail',
    () async {
      final ChatTestTopology topology = ChatTestTopology(
        SessionId('session-run-responses'),
      );
      addTearDown(topology.close);
      Future<DevelopmentSelfHostingRunResult> execute(
        String identity,
        ModelPort model,
      ) => executeDevelopmentSelfHostingRun(
        identity: identity,
        lifecycle: topology.lifecycle,
        sessions: topology.chat.sessions,
        sessionId: topology.session.id,
        prompt: identity,
        instructions: 'Respond.',
        model: model,
        catalog: _catalog(<String>['read_file']),
        maxModelInvocations: 1,
      );
      Map<String, Object?> summary(DevelopmentSelfHostingRunResult result) =>
          developmentSelfHostingSummaryJson(
            result: result,
            selectedModel: 'fake-model',
            git: _emptyGitEvidence,
          );

      final DevelopmentSelfHostingRunResult first = await execute(
        'first',
        const _FinalModel(),
      );
      final Map<String, Object?> firstSummary = summary(first);
      expect(first.run.state, RunState.completed);
      expect(
        (firstSummary['run']!
            as Map<String, Object?>)['finalAssistantResponse'],
        'Complete.',
      );

      final DevelopmentSelfHostingRunResult second = await execute(
        'second',
        _AlwaysProposalModel(),
      );
      final Map<String, Object?> secondSummary = summary(second);
      final Map<String, Object?> failedRun =
          secondSummary['run']! as Map<String, Object?>;
      expect(second.run.state, RunState.failed);
      expect(second.run.failure, isA<ModelInvocationLimitExceeded>());
      expect(failedRun['hasFinalAssistantResponse'], isFalse);
      expect(failedRun['finalAssistantResponse'], isNull);
      expect(second.finalAssistantResponse, isNull);

      final DevelopmentSelfHostingRunResult third = await execute(
        'third',
        const _FinalModel(response: 'Third response.'),
      );
      final Map<String, Object?> thirdRun =
          summary(third)['run']! as Map<String, Object?>;
      expect(third.run.state, RunState.completed);
      expect(thirdRun['hasFinalAssistantResponse'], isTrue);
      expect(thirdRun['finalAssistantResponse'], 'Third response.');
      expect(summary(first), firstSummary);
      expect(summary(second), secondSummary);
      expect(first.finalAssistantResponse, 'Complete.');
      expect(first.session, same(second.session));
      expect(first.session, same(third.session));
      expect(
        first.session.snapshot().entries.map((entry) => entry.content),
        <String>['first', 'Complete.', 'second', 'third', 'Third response.'],
      );
    },
  );

  test('ChatGPT requires matching reported effective models', () async {
    final DevelopmentSelfHostingRunResult matching = await _executeRun(
      identity: 'matching-model',
      sessionId: SessionId('session-matching-model'),
      prompt: 'Complete.',
      instructions: 'Respond.',
      model: _FinalModel(),
      catalog: ToolCatalog(),
      maxModelInvocations: 1,
    );
    final DevelopmentSelfHostingRunResult substituted = await _executeRun(
      identity: 'substituted-model',
      sessionId: SessionId('session-substituted-model'),
      prompt: 'Complete.',
      instructions: 'Respond.',
      model: _FinalModel(effectiveModel: 'substituted-model'),
      catalog: ToolCatalog(),
      maxModelInvocations: 1,
    );
    final DevelopmentSelfHostingRunResult unreported = await _executeRun(
      identity: 'unreported-model',
      sessionId: SessionId('session-unreported-model'),
      prompt: 'Complete.',
      instructions: 'Respond.',
      model: const _FinalModel(effectiveModel: null),
      catalog: ToolCatalog(),
      maxModelInvocations: 1,
    );
    final DevelopmentSelfHostingRunResult noCompletedSettlement =
        await _executeRun(
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

  test('reports deterministic proposal counts in model-start order', () {
    final ChatSessionState session = ChatSessionState(
      SessionId('session-proposal-counts'),
    );
    final AgentRun run = AgentRun(
      id: RunId('run-proposal-counts'),
      sessionId: session.id,
    )..start();
    // Reuse aliases and call IDs across turns; only model invocation IDs group
    // proposals. No preparation or execution is needed for reporter evidence.
    for (final (String id, int count) in <(String, int)>[
      ('model-z', 2),
      ('model-a', 0),
      ('model-m', 1),
    ]) {
      final ModelInvocationId invocationId = ModelInvocationId(id);
      run.record(ModelInvocationStarted(invocationId));
      for (var index = 0; index < count; index++) {
        run.record(
          ModelOutputObserved(
            invocationId: invocationId,
            item: ModelToolProposalOutput(
              ProviderToolProposal(
                providerCallId: 'call-$index',
                alias: 'apply_patch',
                arguments: _patchArguments,
              ),
            ),
          ),
        );
      }
      // Keep the last invocation unterminated to test starts, not settlements.
      if (id != 'model-m') {
        run.record(
          ModelInvocationSettled(
            invocationId: invocationId,
            settlement: ModelSettlement.completed,
            incompleteReason: null,
            metadata: ModelTerminalMetadata(effectiveModel: 'fake-model'),
          ),
        );
      }
    }
    run.cancel();
    final DevelopmentSelfHostingRunResult result =
        DevelopmentSelfHostingRunResult(
          run: run,
          session: session,
          finalAssistantResponse: null,
          executionFailure: null,
          executionStackTrace: null,
        );
    final String journalBefore = jsonEncode(
      developmentSelfHostingJournalJson(result),
    );
    final Map<String, Object?> summary = developmentSelfHostingSummaryJson(
      result: result,
      selectedModel: 'fake-model',
      git: _emptyGitEvidence,
    );
    final Map<String, Object?> aggregates =
        summary['aggregates']! as Map<String, Object?>;
    expect(aggregates['toolProposalCount'], 3);
    expect(aggregates['modelInvocationsWithToolProposals'], 2);
    expect(aggregates['multiProposalModelInvocations'], 1);
    expect(aggregates['maxToolProposalsPerModelInvocation'], 2);
    expect(aggregates['toolProposalCountsByModelInvocation'], <Object?>[
      <String, Object?>{'modelInvocationId': 'model-z', 'toolProposalCount': 2},
      <String, Object?>{'modelInvocationId': 'model-a', 'toolProposalCount': 0},
      <String, Object?>{'modelInvocationId': 'model-m', 'toolProposalCount': 1},
    ]);
    expect(aggregates['preparedToolCount'], 0);
    expect(aggregates['executedToolCount'], 0);
    expect(aggregates['patchEditCount'], 0);
    final Map<String, Object?> tools =
        summary['tools']! as Map<String, Object?>;
    expect(tools['unpreparedProposals'], hasLength(3));
    expect(
      jsonEncode(tools['proposals']),
      contains(jsonEncode(_patchArguments)),
    );
    final String markdown = developmentSelfHostingSummaryMarkdown(summary);
    expect(markdown, contains('| Tool proposals | 3 |'));
    expect(markdown, contains('| Model invocations with tool proposals | 2 |'));
    expect(markdown, contains('| Multi-proposal model invocations | 1 |'));
    expect(
      markdown,
      contains('| Max tool proposals per model invocation | 2 |'),
    );
    expect(markdown, isNot(contains('"edits"')));
    expect(markdown, isNot(contains('caf\u00e9')));
    expect(markdown, isNot(contains('\u8336')));
    expect(markdown, isNot(contains('na\u00efve')));
    final Map<String, Object?> repeated = developmentSelfHostingSummaryJson(
      result: result,
      selectedModel: 'fake-model',
      git: _emptyGitEvidence,
    );
    expect(jsonEncode(repeated), jsonEncode(summary));
    expect(developmentSelfHostingSummaryMarkdown(repeated), markdown);
    expect(
      jsonEncode(developmentSelfHostingJournalJson(result)),
      journalBefore,
    );
  });

  test('reports zero proposal metrics for empty and proposal-free Runs', () {
    for (final bool startModel in <bool>[false, true]) {
      final ChatSessionState session = ChatSessionState(
        SessionId('session-zero-proposals'),
      );
      final AgentRun run = AgentRun(
        id: RunId('run-zero-proposals'),
        sessionId: session.id,
      )..start();
      if (startModel) {
        run.record(ModelInvocationStarted(ModelInvocationId('model-zero')));
      }
      run.cancel();
      final Map<String, Object?> summary = developmentSelfHostingSummaryJson(
        result: DevelopmentSelfHostingRunResult(
          run: run,
          session: session,
          finalAssistantResponse: null,
          executionFailure: null,
          executionStackTrace: null,
        ),
        selectedModel: 'fake-model',
        git: _emptyGitEvidence,
      );
      final Map<String, Object?> aggregates =
          summary['aggregates']! as Map<String, Object?>;
      expect(aggregates['toolProposalCount'], 0);
      expect(aggregates['modelInvocationsWithToolProposals'], 0);
      expect(aggregates['multiProposalModelInvocations'], 0);
      expect(aggregates['maxToolProposalsPerModelInvocation'], 0);
      expect(aggregates['toolProposalCountsByModelInvocation'], <Object?>[
        if (startModel)
          <String, Object?>{
            'modelInvocationId': 'model-zero',
            'toolProposalCount': 0,
          },
      ]);
      final String markdown = developmentSelfHostingSummaryMarkdown(summary);
      expect(markdown, contains('| Tool proposals | 0 |'));
      expect(
        markdown,
        contains('| Model invocations with tool proposals | 0 |'),
      );
      expect(markdown, contains('| Multi-proposal model invocations | 0 |'));
      expect(
        markdown,
        contains('| Max tool proposals per model invocation | 0 |'),
      );
    }
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
      final DevelopmentSelfHostingRunResult result = await _executeRun(
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
      expect(aggregates['patchEditCount'], 4);
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
      expect(_attemptEvidence(attempts, 'apply_patch'), <String, Object?>{
        'relativePath': 'lib/a.dart',
        'expectedRevision': 'r1',
        'editCount': 2,
        'resultingRevision': null,
        'failureCode': 'revision_conflict',
      });
      expect(
        _attemptEvidence(attempts, 'apply_patch', last: true),
        <String, Object?>{
          'relativePath': 'lib/a.dart',
          'expectedRevision': 'r1',
          'editCount': 2,
          'resultingRevision': 'r2',
          'failureCode': null,
        },
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
        allOf(
          contains('## Model Usage'),
          contains('| Patch edits | 4 |'),
          contains('editCount=2'),
          isNot(contains('whole file text')),
          isNot(contains('caf\u00e9')),
          isNot(contains('\u8336')),
          isNot(contains('na\u00efve')),
        ),
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
      final List<Map<String, Object?>> journalRecords =
          (journal['records']! as List<Object?>).cast<Map<String, Object?>>();
      final List<Map<String, Object?>> patchInvocations = journalRecords
          .where((record) => record['event'] == 'toolInvocationPrepared')
          .map((record) => record['invocation']! as Map<String, Object?>)
          .where(
            (invocation) =>
                (invocation['proposal']! as Map<String, Object?>)['alias'] ==
                'apply_patch',
          )
          .toList();
      expect(patchInvocations, hasLength(2));
      for (final Map<String, Object?> invocation in patchInvocations) {
        expect(invocation['canonicalArguments'], _patchArguments);
        expect(
          (invocation['proposal']! as Map<String, Object?>)['arguments'],
          _patchArguments,
        );
      }
      final Map<String, Object?> patchSuccess = journalRecords.singleWhere(
        (record) =>
            record['event'] == 'toolExecutionCompleted' &&
            record['invocationId'] == patchInvocations.last['id'],
      );
      expect(
        patchSuccess['outcome'],
        containsPair(
          'modelContent',
          'Patched: "lib/a.dart"\nEdits applied: 2\nRevision: "r2"',
        ),
      );
      expect(
        (patchSuccess['outcome']! as Map<String, Object?>)['hostData'],
        <String, Object?>{
          'environmentId': 'environment-fixture',
          'relativePath': 'lib/a.dart',
          'editCount': 2,
          'newRevision': 'r2',
        },
      );
    },
  );

  test(
    'failed Run reports prepared patch failures but excludes unprepared edits',
    () async {
      final Directory container = await Directory.systemTemp.createTemp(
        'adele-self-hosting-failure-test-',
      );
      addTearDown(() async {
        if (await container.exists()) await container.delete(recursive: true);
      });
      final _GitFixture git = await _createGitFixture(container);
      // Deliberately differ from the proposal to verify canonical edit counts.
      final Map<String, Object?> canonicalPatchArguments = <String, Object?>{
        ..._patchArguments,
        'edits': <Object?>[
          ..._patchArguments['edits']! as List<Object?>,
          <String, Object?>{'search': 'na\u00efve\n', 'replace': 'caf\u00e9'},
        ],
      };
      final DevelopmentSelfHostingRunResult failed = await _executeRun(
        identity: 'failed-evidence',
        sessionId: SessionId('session-failed-evidence'),
        prompt: 'Keep proposing.',
        instructions: 'Exercise the ceiling.',
        model: _EvidenceModel(
          turns: const <String?>[
            'apply_patch',
            'apply_patch',
            'apply_patch',
            'apply_patch',
            'apply_patch',
            'apply_patch',
          ],
        ),
        catalog: _catalog(<String>[
          'apply_patch',
        ], canonicalPatchArguments: canonicalPatchArguments),
        maxModelInvocations: 6,
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
              maxModelInvocations: 6,
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
      final Map<String, Object?> summary =
          jsonDecode(
                await File('${runDirectory.path}/summary.json').readAsString(),
              )
              as Map<String, Object?>;
      final Map<String, Object?> aggregates =
          summary['aggregates']! as Map<String, Object?>;
      expect(aggregates['patchEditCount'], 15);
      expect(aggregates['toolProposalCount'], 6);
      expect(aggregates['preparedToolCount'], 5);
      expect(aggregates['executedToolCount'], 5);
      expect(aggregates['failedToolCount'], 4);
      expect(aggregates['revisionConflictCount'], 1);
      final Map<String, Object?> tools =
          summary['tools']! as Map<String, Object?>;
      final List<Map<String, Object?>> attempts =
          (tools['attempts']! as List<Object?>).cast<Map<String, Object?>>();
      expect(attempts, hasLength(5));
      const List<String?> failureCodes = <String?>[
        'revision_conflict',
        null,
        'patch_target_not_found',
        'patch_target_ambiguous',
        'no_change',
      ];
      for (var index = 0; index < attempts.length; index++) {
        expect(attempts[index]['canonicalArguments'], canonicalPatchArguments);
        expect(attempts[index]['proposedArguments'], _patchArguments);
        expect(attempts[index]['evidence'], <String, Object?>{
          'relativePath': 'lib/a.dart',
          'expectedRevision': 'r1',
          'editCount': 3,
          'resultingRevision': index == 1 ? 'r2' : null,
          'failureCode': failureCodes[index],
          if (index == 2) 'failedEditIndex': 1,
          if (index == 3) 'failedEditIndex': 0,
        });
      }
      final List<Map<String, Object?>> proposals =
          (tools['proposals']! as List<Object?>).cast<Map<String, Object?>>();
      expect(proposals, hasLength(6));
      for (var index = 0; index < proposals.length; index++) {
        expect(proposals[index]['providerCallId'], 'call-${index + 1}');
        expect(proposals[index]['arguments'], _patchArguments);
      }
      final List<Object?> unprepared =
          tools['unpreparedProposals']! as List<Object?>;
      expect(unprepared, <Object?>[proposals.last]);
      expect(unprepared.single, isNot(contains('reason')));
      expect(proposals.last['prepared'], isFalse);
      expect(proposals.last['toolInvocationId'], isNull);
      final String markdown = await File(
        '${runDirectory.path}/summary.md',
      ).readAsString();
      expect(markdown, contains('| Patch edits | 15 |'));
      expect(markdown, contains('editCount=3'));
      expect(markdown, contains('failedEditIndex=1'));
      expect(markdown, contains('failedEditIndex=0'));
      expect(
        markdown,
        contains(
          '`{"relativePath":"lib/a.dart","expectedRevision":"r1",'
          '"editCount":2,"searchBytes":8,"replaceBytes":10}`',
        ),
      );
      expect(markdown, isNot(contains('"edits"')));
      expect(markdown, isNot(contains('caf\u00e9')));
      expect(markdown, isNot(contains('\u8336')));
      expect(markdown, isNot(contains('na\u00efve')));
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
    const String unusualPath =
        'café `tick` "quoted" \\ tab\tline\n'
        '# injected heading\n- injected item.dart';
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
    final DevelopmentSelfHostingRunResult run = await _executeRun(
      identity: 'unusual-path-markdown',
      sessionId: SessionId('session-unusual-path-markdown'),
      prompt: 'Complete.',
      instructions: 'Respond.',
      model: _FinalModel(),
      catalog: ToolCatalog(),
      maxModelInvocations: 1,
    );
    final Map<String, Object?> summary = developmentSelfHostingSummaryJson(
      result: run,
      selectedModel: 'fake-model',
      git: evidence,
      taskBaseline: git.startingHead,
    );
    final Map<String, Object?> structuredTask =
        ((summary['git']! as Map<String, Object?>)['taskWorktree']!
            as Map<String, Object?>);
    final String markdown = developmentSelfHostingSummaryMarkdown(summary);
    final List<String> changedPathRecords = const LineSplitter()
        .convert(markdown)
        .where((String line) => line.startsWith('- `"café'))
        .toList(growable: false);

    expect(structuredTask['changedFiles'], contains(unusualPath));
    expect(changedPathRecords, hasLength(1));
    expect(changedPathRecords.single, contains(r'\u0060tick\u0060'));
    expect(changedPathRecords.single, contains(r'\n# injected heading\n'));
    expect(markdown, isNot(contains('\n# injected heading\n')));
    expect(markdown, isNot(contains('\n- injected item.dart\n')));
    expect(
      RegExp(
        r'^## Final Assistant Response$',
        multiLine: true,
      ).allMatches(markdown),
      hasLength(1),
    );
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
    final DevelopmentSelfHostingRunResult run = await _executeRun(
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
    expect(summary['aggregates'], containsPair('patchEditCount', 0));
    final Map<String, Object?> aggregates =
        summary['aggregates']! as Map<String, Object?>;
    expect(aggregates['toolProposalCount'], 0);
    expect(aggregates['modelInvocationsWithToolProposals'], 0);
    expect(aggregates['multiProposalModelInvocations'], 0);
    expect(aggregates['maxToolProposalsPerModelInvocation'], 0);
    expect(aggregates['toolProposalCountsByModelInvocation'], isEmpty);
    expect(
      run['failure'],
      allOf(
        containsPair('type', 'StateError'),
        containsPair('message', contains('setup failed')),
      ),
    );
    expect(
      developmentSelfHostingSummaryMarkdown(summary),
      allOf(
        contains('setup failed'),
        contains('| Tool proposals | 0 |'),
        contains('| Model invocations with tool proposals | 0 |'),
        contains('| Multi-proposal model invocations | 0 |'),
        contains('| Max tool proposals per model invocation | 0 |'),
      ),
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

ToolCatalog _catalog(
  Iterable<String> aliases, {
  Map<String, Object?>? canonicalPatchArguments,
}) {
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
        executable: _FixtureTool(
          alias,
          canonicalPatchArguments: canonicalPatchArguments,
        ),
      ),
    );
  }
  return catalog;
}

Future<DevelopmentSelfHostingRunResult> _executeRun({
  required String identity,
  required SessionId sessionId,
  required String prompt,
  required String instructions,
  required ModelPort model,
  required ToolCatalog catalog,
  required int maxModelInvocations,
}) {
  final ChatTestTopology topology = ChatTestTopology(sessionId);
  addTearDown(topology.close);
  return executeDevelopmentSelfHostingRun(
    identity: identity,
    lifecycle: topology.lifecycle,
    sessions: topology.chat.sessions,
    sessionId: topology.session.id,
    prompt: prompt,
    instructions: instructions,
    model: model,
    catalog: catalog,
    maxModelInvocations: maxModelInvocations,
  );
}

final class _FinalModel implements ModelPort {
  const _FinalModel({
    this.effectiveModel = 'fake-model',
    this.requests,
    this.response = 'Complete.',
  });

  final String? effectiveModel;
  final List<SemanticModelRequest>? requests;
  final String response;

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    requests?.add(request);
    yield ModelOutputItemCompleted(
      invocationId: request.invocationId,
      item: ModelTextOutput(response),
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

const Map<String, Object?> _patchArguments = <String, Object?>{
  'relativePath': 'lib/a.dart',
  'expectedRevision': 'r1',
  'edits': <Object?>[
    <String, Object?>{'search': 'caf\u00e9', 'replace': '\u8336'},
    <String, Object?>{'search': '\u8336', 'replace': 'na\u00efve\n'},
  ],
};

final class _EvidenceModel implements ModelPort {
  _EvidenceModel({this.turns = _defaultTurns});

  static const List<String?> _defaultTurns = <String?>[
    'search',
    'read_file',
    'apply_patch',
    'apply_patch',
    'create_file',
    'delete_file',
    'run_command',
    null,
  ];

  final List<String?> turns;
  var _invocations = 0;

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    final int invocation = ++_invocations;
    final String? alias = turns[invocation - 1];
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
    'apply_patch' => _patchArguments,
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
  _FixtureTool(this.alias, {this.canonicalPatchArguments});

  final String alias;
  final Map<String, Object?>? canonicalPatchArguments;
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
    if (alias == 'apply_patch') {
      final String relativePath = arguments.snapshot['relativePath']! as String;
      final int editCount =
          (arguments.snapshot['edits']! as List<Object?>).length;
      final String? failureCode = switch (_executions) {
        1 => 'revision_conflict',
        3 => 'patch_target_not_found',
        4 => 'patch_target_ambiguous',
        5 => 'no_change',
        _ => null,
      };
      const String newRevision = 'r2';
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: failureCode == null
              ? ToolOutcomeDisposition.success
              : ToolOutcomeDisposition.failure,
          failureKind: failureCode == null ? null : ToolFailureKind.domain,
          effectCertainty: failureCode == null
              ? EffectCertainty.knownOccurred
              : EffectCertainty.knownNotOccurred,
          modelContent: failureCode == null
              ? 'Patched: ${jsonEncode(relativePath)}\n'
                    'Edits applied: $editCount\n'
                    'Revision: ${jsonEncode(newRevision)}'
              : 'Fixture patch failed: $failureCode.',
          hostData: <String, Object?>{
            'environmentId': 'environment-fixture',
            'relativePath': relativePath,
            'editCount': editCount,
            if (failureCode == null) 'newRevision': newRevision,
            'code': ?failureCode,
            if (_executions == 3) 'failedEditIndex': 1,
            if (_executions == 4) 'failedEditIndex': 0,
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
  ) => CanonicalToolArguments(
    alias == 'apply_patch'
        ? canonicalPatchArguments ?? proposedArguments
        : proposedArguments,
  );

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
