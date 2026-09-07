import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/development/agent/agent_capability_adapters.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'source_coding_live_test_support.dart';

const String _originalFragment = '    this.maxModelInvocations = 8,';
const String _replacementFragment = '    this.maxModelInvocations = 9,';
const String _validationPrompt =
    'Read app/lib/development/agent/simple_tool_loop_strategy.dart. '
    'Change the default maxModelInvocations assignment from 8 to 9 using '
    'apply_patch. Use the exact opaque Revision returned by read_file as '
    'expectedRevision. After the patch succeeds, validate the Task worktree '
    'by using run_command to run git diff --check from the Environment root. '
    'If validation succeeds, report that the source change was made and that '
    'git diff --check passed.';
const String _validationInstructions =
    'You must inspect the exact requested file with read_file before editing. '
    'Do not invent, infer, transform, hash, or derive the revision. Copy the '
    'exact opaque Revision visible in the read_file result into apply_patch as '
    'expectedRevision. Use apply_patch for the edit. If a safe patch attempt '
    'fails, re-read before retrying. For validation, use run_command directly '
    'rather than constructing a shell command. Run the git executable with '
    'arguments ["diff", "--check"] from the Environment root. Set program to '
    'exactly "git"; do not combine the executable and arguments into one '
    'string. Do not use sh -c, bash -c, pipes, redirects, or command chaining. '
    'After a successful validation result, report completion.';

void main() {
  final bool enabled =
      Platform.environment['ADELE_OPENAI_SOURCE_VALIDATION_LIVE_TEST'] == '1';
  late SourceCodingLiveArtifacts artifacts;

  setUpAll(() async {
    if (!enabled) return;
    artifacts = await SourceCodingLiveArtifacts.compile(
      'phase-v-c3-openai-source-validation-live',
    );
  });

  test(
    'OpenAI API key patches and validates maintained ADELE source',
    () async {
      final String selectedModel = _requiredEnvironment(
        'ADELE_OPENAI_TEST_MODEL',
      );
      final SourceCodingLiveHarness harness =
          await SourceCodingLiveHarness.start(
            artifacts: artifacts,
            hostEnvironment: <String, String>{
              'OPENAI_API_KEY': _requiredEnvironment('OPENAI_API_KEY'),
              'ADELE_OPENAI_ENDPOINT': 'https://api.openai.com/v1/responses',
            },
            identity: 'openai-api-key-validation',
            taskTitle: 'Edit and validate ADELE source with OpenAI API key',
            enableCommandTools: true,
          );
      addTearDown(harness.close);
      expect(
        harness.catalog.materialize().tools.map(
          (MaterializedTool tool) => tool.modelDefinition.alias,
        ),
        <String>['read_file', 'apply_patch', 'search', 'run_command'],
      );
      final SourceCodingLiveProviderActivation model =
          await startOpenAiApiKeyProvider(
            host: harness.host,
            registry: harness.registry,
            artifact: artifacts.openAiArtifact,
          );
      addTearDown(model.close);
      final ModelProviderCapabilityAdapter modelAdapter =
          ModelProviderCapabilityAdapter(
            harness.registry.resolve(
              modelProviderCapability,
              providerId: ProviderId(openAiApiKeyProviderId),
            ),
            selectedModel: selectedModel,
          );
      final File checkoutSource = File(
        '${artifacts.repository}/$sourceCodingStrategyPath',
      );
      final String originalCheckoutText = await checkoutSource.readAsString();
      final String originalProjectText = await harness.readProjectSourceFile(
        sourceCodingStrategyPath,
      );
      expect(originalProjectText, originalCheckoutText);
      final String expectedTaskText = _expectedMutation(originalProjectText);
      expect(expectedTaskText, contains(_replacementFragment));
      expect(expectedTaskText, isNot(contains(_originalFragment)));

      final SourceCodingLiveResult result = await harness.run(
        identity: 'openai-api-key-validation',
        model: modelAdapter,
        userPrompt: _validationPrompt,
        developmentInstructions: _validationInstructions,
      );

      final _ValidationEvidence evidence = _expectSuccessfulValidationRun(
        result: result,
        authority: harness.authority,
        originalText: originalProjectText,
        expectedText: expectedTaskText,
      );
      final EnvironmentTextFile resultingFile = await harness
          .readEnvironmentFile(sourceCodingStrategyPath);
      expect(resultingFile.text, expectedTaskText);
      expect(resultingFile.revision, evidence.newRevision);
      expect(resultingFile.revision, isNot(evidence.readRevision));
      expect(
        await harness.readTaskWorktreeFile(sourceCodingStrategyPath),
        expectedTaskText,
      );
      expect(harness.taskWorktreePath, isNot(harness.projectSourcePath));
      expect(
        await harness.readProjectSourceFile(sourceCodingStrategyPath),
        originalProjectText,
      );
      expect(await checkoutSource.readAsString(), originalCheckoutText);

      // Keep successful paid-smoke evidence visible in the test transcript.
      print('V-C3 selected model: $selectedModel');
      print('V-C3 effective model: ${evidence.effectiveModel}');
      print('V-C3 read revision R1: ${evidence.readRevision}');
      print('V-C3 patch expectedRevision matched R1: true');
      print('V-C3 resulting revision R2: ${evidence.newRevision}');
      print(
        'V-C3 tool proposal sequence: '
        '${evidence.proposalAliases.join(' -> ')}',
      );
      print('V-C3 patch retry occurred: ${evidence.patchProposalCount > 1}');
      print(
        'V-C3 direct run_command succeeded on first proposal: '
        '${evidence.commandProposalCount == 1}',
      );
      print(
        'V-C3 command canonical arguments: program="git", '
        'arguments=["diff","--check"], workingDirectory="", '
        'timeoutSeconds=${evidence.commandTimeoutSeconds}',
      );
      print(
        'V-C3 command policy target: '
        'adele-environment:/${harness.authority.environmentId.value}/',
      );
      print(
        'V-C3 command outcome: exited, exitCode=0, '
        'effectCertainty=knownOccurred',
      );
      print('V-C3 final assistant: ${evidence.finalAnswer}');

      await model.close();
      await harness.close();
    },
    skip: enabled
        ? false
        : 'Set ADELE_OPENAI_SOURCE_VALIDATION_LIVE_TEST=1 and provide '
              'OPENAI_API_KEY plus ADELE_OPENAI_TEST_MODEL to enable the paid '
              'full-stack source-validation smoke.',
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

_ValidationEvidence _expectSuccessfulValidationRun({
  required SourceCodingLiveResult result,
  required SessionEnvironmentAuthority authority,
  required String originalText,
  required String expectedText,
}) {
  expect(result.run.state, RunState.completed);
  final List<ExecutionEventRecord> records = result.run.journal.records;
  final List<_ToolAttempt> reads = _toolAttempts(records, 'read_file');
  final List<_ToolAttempt> patches = _toolAttempts(records, 'apply_patch');
  final List<_ToolAttempt> commands = _toolAttempts(records, 'run_command');
  expect(reads, isNotEmpty);
  expect(patches, isNotEmpty);
  expect(commands, hasLength(1));

  final List<_ToolAttempt> successfulPatches = patches
      .where(
        (_ToolAttempt attempt) =>
            attempt.outcome.disposition == ToolOutcomeDisposition.success,
      )
      .toList(growable: false);
  expect(successfulPatches, hasLength(1));
  final _ToolAttempt successfulPatch = successfulPatches.single;
  final ToolInvocation patchInvocation = successfulPatch.prepared.invocation;
  expect(
    patchInvocation.canonicalArguments['relativePath'],
    sourceCodingStrategyPath,
  );
  expect(
    patchInvocation.tool.definition.id.value,
    'dev.adele.plugin.filesystem-tools.apply-patch',
  );
  expect(
    successfulPatch.outcome.effectCertainty,
    EffectCertainty.knownOccurred,
  );
  expect(successfulPatch.outcome.failureKind, isNull);

  const Set<String> safeFailureCodes = <String>{
    'patch_target_not_found',
    'patch_target_ambiguous',
    environmentRevisionConflictCode,
  };
  for (final _ToolAttempt attempt in patches.where(
    (_ToolAttempt attempt) => !identical(attempt, successfulPatch),
  )) {
    expect(attempt.outcome.disposition, ToolOutcomeDisposition.failure);
    expect(attempt.outcome.effectCertainty, EffectCertainty.knownNotOccurred);
    expect(attempt.outcome.hostData['code'], isIn(safeFailureCodes));
    expect(
      attempt.terminalRecord.sequence,
      lessThan(successfulPatch.preparedRecord.sequence),
    );
    expect(
      reads.where(
        (_ToolAttempt read) =>
            read.terminalRecord.sequence > attempt.terminalRecord.sequence &&
            read.terminalRecord.sequence <
                successfulPatch.preparedRecord.sequence &&
            read.outcome.disposition == ToolOutcomeDisposition.success &&
            read.prepared.invocation.canonicalArguments['relativePath'] ==
                sourceCodingStrategyPath,
      ),
      isNotEmpty,
    );
  }

  final Object? search = patchInvocation.canonicalArguments['search'];
  final Object? replace = patchInvocation.canonicalArguments['replace'];
  expect(search, isA<String>());
  expect(replace, isA<String>());
  expect(
    _replaceUnique(originalText, search! as String, replace! as String),
    expectedText,
  );

  final Object? expectedRevision =
      patchInvocation.canonicalArguments['expectedRevision'];
  expect(expectedRevision, isA<String>());
  final List<_ToolAttempt> relevantReads = reads
      .where((_ToolAttempt attempt) {
        return attempt.terminalRecord.sequence <
                successfulPatch.preparedRecord.sequence &&
            attempt.outcome.disposition == ToolOutcomeDisposition.success &&
            attempt.prepared.invocation.canonicalArguments['relativePath'] ==
                sourceCodingStrategyPath &&
            attempt.outcome.hostData['revision'] == expectedRevision;
      })
      .toList(growable: false);
  expect(relevantReads, isNotEmpty);
  final _ToolAttempt relevantRead = relevantReads.last;
  final String readRevision = expectedRevision! as String;
  expect(readRevision, isNotEmpty);
  expect(
    relevantRead.prepared.invocation.tool.definition.id.value,
    'dev.adele.plugin.filesystem-tools.read-file',
  );
  expect(relevantRead.outcome.effectCertainty, EffectCertainty.knownOccurred);
  expect(relevantRead.outcome.failureKind, isNull);
  expect(
    relevantRead.outcome.hostData['environmentId'],
    authority.environmentId.value,
  );
  expect(
    relevantRead.outcome.hostData['relativePath'],
    sourceCodingStrategyPath,
  );
  expect(relevantRead.outcome.hostData['text'], originalText);
  expect(
    relevantRead.outcome.modelContent,
    'File: ${jsonEncode(sourceCodingStrategyPath)}\n'
    'Revision: ${jsonEncode(readRevision)}\n\n'
    '$originalText',
  );
  expect(
    relevantRead.terminalRecord.sequence,
    lessThan(successfulPatch.preparedRecord.sequence),
  );

  expect(
    successfulPatch.outcome.hostData['environmentId'],
    authority.environmentId.value,
  );
  expect(
    successfulPatch.outcome.hostData['relativePath'],
    sourceCodingStrategyPath,
  );
  final Object? newRevisionValue =
      successfulPatch.outcome.hostData['newRevision'];
  expect(newRevisionValue, isA<String>());
  final String newRevision = newRevisionValue! as String;
  expect(newRevision, isNotEmpty);
  expect(newRevision, isNot(readRevision));
  expect(
    successfulPatch.outcome.modelContent,
    'Patched: ${jsonEncode(sourceCodingStrategyPath)}\n'
    'Revision: ${jsonEncode(newRevision)}',
  );

  final ExecutionEventRecord patchPolicyRecord = _policyRecord(
    records,
    patchInvocation.id,
  );
  final ToolPolicyEvaluated patchPolicy =
      patchPolicyRecord.event as ToolPolicyEvaluated;
  expect(patchPolicy.decision, ToolPolicyDecision.allow);
  expect(patchPolicy.effects.effects, <ToolEffect>{ToolEffect.sourceMutation});
  expect(patchPolicy.effects.uncertainty, EffectUncertainty.none);
  expect(
    patchPolicy.effects.targets.single.uri.toString(),
    'adele-environment:/${authority.environmentId.value}/'
    '$sourceCodingStrategyPath',
  );
  final ExecutionEventRecord patchExecutionStarted = _executionStartedRecord(
    records,
    patchInvocation.id,
  );
  expect(
    successfulPatch.preparedRecord.sequence,
    lessThan(patchPolicyRecord.sequence),
  );
  expect(patchPolicyRecord.sequence, lessThan(patchExecutionStarted.sequence));
  expect(
    patchExecutionStarted.sequence,
    lessThan(successfulPatch.terminalRecord.sequence),
  );

  final _ToolAttempt command = commands.single;
  final ToolInvocation commandInvocation = command.prepared.invocation;
  expect(
    commandInvocation.tool.definition.id.value,
    'dev.adele.plugin.command-tools.run-command',
  );
  expect(commandInvocation.canonicalArguments['program'], 'git');
  expect(
    commandInvocation.canonicalArguments['program'],
    isNot('git diff --check'),
  );
  expect(commandInvocation.canonicalArguments['arguments'], <String>[
    'diff',
    '--check',
  ]);
  expect(commandInvocation.canonicalArguments['workingDirectory'], '');
  final Object? timeout =
      commandInvocation.canonicalArguments['timeoutSeconds'];
  expect(timeout, isA<int>());
  final int commandTimeoutSeconds = timeout! as int;
  expect(commandTimeoutSeconds, inInclusiveRange(1, 600));
  expect(command.outcome.disposition, ToolOutcomeDisposition.success);
  expect(command.outcome.effectCertainty, EffectCertainty.knownOccurred);
  expect(command.outcome.failureKind, isNull);
  expect(
    command.outcome.hostData['environmentId'],
    authority.environmentId.value,
  );
  expect(command.outcome.hostData['program'], 'git');
  expect(command.outcome.hostData['arguments'], <String>['diff', '--check']);
  expect(command.outcome.hostData['workingDirectory'], '');
  expect(command.outcome.hostData['timeoutSeconds'], commandTimeoutSeconds);
  expect(command.outcome.hostData['termination'], 'exited');
  expect(command.outcome.hostData['exitCode'], 0);
  expect(
    command.outcome.modelContent,
    _expectedCommandModelContent(command.outcome, commandTimeoutSeconds),
  );

  final ExecutionEventRecord commandPolicyRecord = _policyRecord(
    records,
    commandInvocation.id,
  );
  final ToolPolicyEvaluated commandPolicy =
      commandPolicyRecord.event as ToolPolicyEvaluated;
  expect(commandPolicy.decision, ToolPolicyDecision.allow);
  expect(commandPolicy.effects.effects, <ToolEffect>{
    ToolEffect.processExecution,
  });
  expect(commandPolicy.effects.uncertainty, EffectUncertainty.uncertain);
  expect(
    commandPolicy.effects.targets.single.uri.toString(),
    'adele-environment:/${authority.environmentId.value}/',
  );
  final ExecutionEventRecord commandExecutionStarted = _executionStartedRecord(
    records,
    commandInvocation.id,
  );
  expect(
    successfulPatch.terminalRecord.sequence,
    lessThan(command.preparedRecord.sequence),
  );
  expect(
    command.preparedRecord.sequence,
    lessThan(commandPolicyRecord.sequence),
  );
  expect(
    commandPolicyRecord.sequence,
    lessThan(commandExecutionStarted.sequence),
  );
  expect(
    commandExecutionStarted.sequence,
    lessThan(command.terminalRecord.sequence),
  );

  final List<ExecutionEventRecord> continuationStarts = records
      .where(
        (ExecutionEventRecord record) =>
            record.sequence > command.terminalRecord.sequence &&
            record.event is ModelInvocationStarted,
      )
      .toList(growable: false);
  expect(continuationStarts, isNotEmpty);
  final ExecutionEventRecord finalInvocationStarted = continuationStarts.last;
  final ModelInvocationId finalInvocation =
      (finalInvocationStarted.event as ModelInvocationStarted).invocationId;
  final List<ModelOutputItem> finalOutputs = records
      .map((ExecutionEventRecord record) => record.event)
      .whereType<ModelOutputObserved>()
      .where(
        (ModelOutputObserved event) => event.invocationId == finalInvocation,
      )
      .map((ModelOutputObserved event) => event.item)
      .toList(growable: false);
  expect(finalOutputs.whereType<ModelToolProposalOutput>(), isEmpty);
  final String finalText = finalOutputs
      .whereType<ModelTextOutput>()
      .map((ModelTextOutput output) => output.content)
      .join();
  expect(finalText.trim(), isNotEmpty);
  final String answer =
      (result.session.snapshot().entries.last as AssistantSessionMessage)
          .content;
  expect(answer, finalText);
  final String normalizedAnswer = answer
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), ' ')
      .trim();
  expect(
    _reportsCompletedChange(normalizedAnswer),
    isTrue,
    reason: 'The final answer did not report the requested source change.',
  );
  expect(
    _reportsSuccessfulValidation(normalizedAnswer),
    isTrue,
    reason: 'The final answer did not report successful validation.',
  );
  expect(
    _reportsContradictoryFailure(normalizedAnswer),
    isFalse,
    reason: 'The final answer contradicted the successful Run evidence.',
  );

  final ExecutionEventRecord finalSettlementRecord = records.singleWhere(
    (ExecutionEventRecord record) =>
        record.event is ModelInvocationSettled &&
        (record.event as ModelInvocationSettled).invocationId ==
            finalInvocation,
  );
  final ModelInvocationSettled finalSettlement =
      finalSettlementRecord.event as ModelInvocationSettled;
  expect(finalSettlement.settlement, ModelSettlement.completed);
  final ExecutionEventRecord runCompleted = records.singleWhere(
    (ExecutionEventRecord record) => record.event is RunCompleted,
  );
  expect(
    command.terminalRecord.sequence,
    lessThan(finalInvocationStarted.sequence),
  );
  expect(
    finalInvocationStarted.sequence,
    lessThan(finalSettlementRecord.sequence),
  );
  expect(finalSettlementRecord.sequence, lessThan(runCompleted.sequence));

  final List<String> proposalAliases = records
      .map((ExecutionEventRecord record) => record.event)
      .whereType<ModelOutputObserved>()
      .map((ModelOutputObserved event) => event.item)
      .whereType<ModelToolProposalOutput>()
      .map((ModelToolProposalOutput output) => output.proposal.alias)
      .toList(growable: false);
  expect(
    proposalAliases,
    containsAllInOrder(<String>['read_file', 'apply_patch', 'run_command']),
  );

  return _ValidationEvidence(
    readRevision: readRevision,
    newRevision: newRevision,
    effectiveModel: finalSettlement.metadata.effectiveModel ?? '<unreported>',
    proposalAliases: proposalAliases,
    patchProposalCount: proposalAliases
        .where((String alias) => alias == 'apply_patch')
        .length,
    commandProposalCount: proposalAliases
        .where((String alias) => alias == 'run_command')
        .length,
    commandTimeoutSeconds: commandTimeoutSeconds,
    finalAnswer: answer,
  );
}

List<_ToolAttempt> _toolAttempts(
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
      return _ToolAttempt(
        preparedRecord: preparedRecord,
        terminalRecord: terminalRecord,
      );
    })
    .toList(growable: false);

ExecutionEventRecord _policyRecord(
  List<ExecutionEventRecord> records,
  ToolInvocationId invocationId,
) => records.singleWhere(
  (ExecutionEventRecord record) =>
      record.event is ToolPolicyEvaluated &&
      (record.event as ToolPolicyEvaluated).invocationId == invocationId,
);

ExecutionEventRecord _executionStartedRecord(
  List<ExecutionEventRecord> records,
  ToolInvocationId invocationId,
) => records.singleWhere(
  (ExecutionEventRecord record) =>
      record.event is ToolExecutionStarted &&
      (record.event as ToolExecutionStarted).invocationId == invocationId,
);

String _expectedCommandModelContent(ToolOutcome outcome, int timeoutSeconds) {
  final String stdout = outcome.hostData['stdout']! as String;
  final String stderr = outcome.hostData['stderr']! as String;
  final Object? stdoutTruncated = outcome.hostData['stdoutTruncated'];
  final Object? stderrTruncated = outcome.hostData['stderrTruncated'];
  return 'Program: "git"\n'
      'Arguments: ["diff","--check"]\n'
      'Working directory: ""\n'
      'Timeout seconds: $timeoutSeconds\n'
      'Termination: exited\n'
      'Exit code: 0\n'
      'Stdout truncated: $stdoutTruncated\n'
      'Stderr truncated: $stderrTruncated\n\n'
      'STDOUT:\n$stdout\n\n'
      'STDERR:\n$stderr';
}

bool _reportsCompletedChange(String answer) {
  final bool completion = <String>[
    'changed',
    'updated',
    'made',
    'completed',
    'set to 9',
    'now 9',
    'now defaults to 9',
  ].any(answer.contains);
  return completion &&
      ((answer.contains('maxmodelinvocations') && answer.contains('9')) ||
          answer.contains('source change') ||
          answer.contains('requested change') ||
          answer.contains('change was made') ||
          answer.contains('change has been made'));
}

bool _reportsSuccessfulValidation(String answer) {
  final bool success = <String>[
    'passed',
    'succeeded',
    'successful',
    'exit code 0',
    'no whitespace errors',
  ].any(answer.contains);
  return success &&
      (answer.contains('git diff check') || answer.contains('validation'));
}

bool _reportsContradictoryFailure(String answer) => <String>[
  'could not',
  'couldn t',
  'unable',
  'failed to',
  'validation failed',
  'git diff check failed',
  'patch failed',
  'not changed',
  'change was not made',
].any(answer.contains);

String _expectedMutation(String original) =>
    _replaceUnique(original, _originalFragment, _replacementFragment);

String _replaceUnique(String original, String search, String replace) {
  final int match = original.indexOf(search);
  if (match < 0) {
    throw StateError('The maintained mutation target is missing.');
  }
  if (original.indexOf(search, match + search.length) >= 0) {
    throw StateError('The maintained mutation target is not unique.');
  }
  return original.replaceRange(match, match + search.length, replace);
}

String _requiredEnvironment(String name) {
  final String? value = Platform.environment[name];
  if (value == null || value.trim().isEmpty) {
    throw StateError('$name is required for the OpenAI validation live test.');
  }
  return value;
}

final class _ToolAttempt {
  const _ToolAttempt({
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

final class _ValidationEvidence {
  const _ValidationEvidence({
    required this.readRevision,
    required this.newRevision,
    required this.effectiveModel,
    required this.proposalAliases,
    required this.patchProposalCount,
    required this.commandProposalCount,
    required this.commandTimeoutSeconds,
    required this.finalAnswer,
  });

  final String readRevision;
  final String newRevision;
  final String effectiveModel;
  final List<String> proposalAliases;
  final int patchProposalCount;
  final int commandProposalCount;
  final int commandTimeoutSeconds;
  final String finalAnswer;
}
