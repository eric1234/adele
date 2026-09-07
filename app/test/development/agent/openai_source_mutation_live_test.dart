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
const String _mutationPrompt =
    'Read app/lib/development/agent/simple_tool_loop_strategy.dart using '
    'read_file. Then use apply_patch to change the default '
    'maxModelInvocations assignment from 8 to 9. Use the exact opaque '
    'Revision returned by read_file as expectedRevision. Use enough exact '
    'surrounding source in the apply_patch search argument that it matches '
    'exactly once. The exact path is supplied, so do not call the search tool. '
    'Do not modify any other source. After apply_patch succeeds, report that '
    'the change was made.';
const String _mutationInstructions =
    'You must inspect the exact requested file with read_file before editing. '
    'Do not invent, infer, transform, or derive the revision. Copy the exact '
    'opaque Revision visible in the read_file result into apply_patch as '
    'expectedRevision. Perform the edit with apply_patch rather than merely '
    'describing it. If a safe patch attempt fails, re-read before retrying. '
    'After the patch succeeds, report completion.';

void main() {
  final bool enabled =
      Platform.environment['ADELE_OPENAI_SOURCE_MUTATION_LIVE_TEST'] == '1';
  late SourceCodingLiveArtifacts artifacts;

  setUpAll(() async {
    if (!enabled) return;
    artifacts = await SourceCodingLiveArtifacts.compile(
      'phase-v-b3-openai-source-mutation-live',
    );
  });

  test(
    'OpenAI API key reads and patches maintained ADELE source',
    () async {
      final SourceCodingLiveHarness harness =
          await SourceCodingLiveHarness.start(
            artifacts: artifacts,
            hostEnvironment: <String, String>{
              'OPENAI_API_KEY': _requiredEnvironment('OPENAI_API_KEY'),
              'ADELE_OPENAI_ENDPOINT': 'https://api.openai.com/v1/responses',
            },
            identity: 'openai-api-key-mutation',
            taskTitle: 'Mutate ADELE source with OpenAI API key',
          );
      addTearDown(harness.close);
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
            selectedModel: _requiredEnvironment('ADELE_OPENAI_TEST_MODEL'),
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
        identity: 'openai-api-key-mutation',
        model: modelAdapter,
        userPrompt: _mutationPrompt,
        developmentInstructions: _mutationInstructions,
      );

      final _MutationEvidence evidence = _expectSuccessfulMutationRun(
        result: result,
        authority: harness.authority,
        originalText: originalProjectText,
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

      await model.close();
      await harness.close();
    },
    skip: enabled
        ? false
        : 'Set ADELE_OPENAI_SOURCE_MUTATION_LIVE_TEST=1 and provide '
              'OPENAI_API_KEY plus ADELE_OPENAI_TEST_MODEL to enable the paid '
              'full-stack source-mutation smoke.',
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

_MutationEvidence _expectSuccessfulMutationRun({
  required SourceCodingLiveResult result,
  required SessionEnvironmentAuthority authority,
  required String originalText,
}) {
  expect(result.run.state, RunState.completed);
  final List<ExecutionEventRecord> records = result.run.journal.records;
  final List<_ToolAttempt> reads = _toolAttempts(records, 'read_file');
  final List<_ToolAttempt> patches = _toolAttempts(records, 'apply_patch');
  expect(_toolAttempts(records, 'create_file'), isEmpty);
  expect(_toolAttempts(records, 'delete_file'), isEmpty);
  expect(reads, isNotEmpty);
  expect(patches, isNotEmpty);

  final List<_ToolAttempt> successfulPatches = patches
      .where(
        (_ToolAttempt attempt) =>
            attempt.outcome.disposition == ToolOutcomeDisposition.success,
      )
      .toList(growable: false);
  expect(successfulPatches, hasLength(1));
  final _ToolAttempt successfulPatch = successfulPatches.single;
  expect(
    successfulPatch.prepared.invocation.canonicalArguments['relativePath'],
    sourceCodingStrategyPath,
  );
  expect(
    successfulPatch.prepared.invocation.tool.definition.id.value,
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
  }

  final Object? expectedRevision = successfulPatch
      .prepared
      .invocation
      .canonicalArguments['expectedRevision'];
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

  final ExecutionEventRecord policyRecord = records.singleWhere(
    (ExecutionEventRecord record) =>
        record.event is ToolPolicyEvaluated &&
        (record.event as ToolPolicyEvaluated).invocationId ==
            successfulPatch.prepared.invocation.id,
  );
  final ToolPolicyEvaluated policy = policyRecord.event as ToolPolicyEvaluated;
  expect(policy.decision, ToolPolicyDecision.allow);
  expect(policy.effects.effects, <ToolEffect>{ToolEffect.sourceMutation});
  expect(policy.effects.uncertainty, EffectUncertainty.none);
  expect(
    policy.effects.targets.single.uri.toString(),
    'adele-environment:/${authority.environmentId.value}/'
    '$sourceCodingStrategyPath',
  );
  expect(
    successfulPatch.preparedRecord.sequence,
    lessThan(policyRecord.sequence),
  );
  final ExecutionEventRecord executionStarted = records.singleWhere(
    (ExecutionEventRecord record) =>
        record.event is ToolExecutionStarted &&
        (record.event as ToolExecutionStarted).invocationId ==
            successfulPatch.prepared.invocation.id,
  );
  expect(policyRecord.sequence, lessThan(executionStarted.sequence));
  expect(
    executionStarted.sequence,
    lessThan(successfulPatch.terminalRecord.sequence),
  );

  final List<ExecutionEventRecord> continuationStarts = records
      .where(
        (ExecutionEventRecord record) =>
            record.sequence > successfulPatch.terminalRecord.sequence &&
            record.event is ModelInvocationStarted,
      )
      .toList(growable: false);
  expect(continuationStarts, isNotEmpty);
  final ModelInvocationId finalInvocation =
      (continuationStarts.last.event as ModelInvocationStarted).invocationId;
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
    normalizedAnswer,
    anyOf(
      contains('change was made'),
      contains('change has been made'),
      contains('successfully'),
      contains('is now 9'),
      contains('to 9'),
    ),
  );
  expect(
    normalizedAnswer,
    isNot(
      anyOf(
        contains('could not'),
        contains('unable'),
        contains('failed'),
        contains('not complete'),
        contains('not made'),
      ),
    ),
  );
  final ExecutionEventRecord finalSettlement = records.singleWhere(
    (ExecutionEventRecord record) =>
        record.event is ModelInvocationSettled &&
        (record.event as ModelInvocationSettled).invocationId ==
            finalInvocation,
  );
  final ExecutionEventRecord runCompleted = records.singleWhere(
    (ExecutionEventRecord record) => record.event is RunCompleted,
  );
  expect(
    (finalSettlement.event as ModelInvocationSettled).settlement,
    ModelSettlement.completed,
  );
  expect(
    successfulPatch.terminalRecord.sequence,
    lessThan(continuationStarts.last.sequence),
  );
  expect(continuationStarts.last.sequence, lessThan(finalSettlement.sequence));
  expect(finalSettlement.sequence, lessThan(runCompleted.sequence));

  return _MutationEvidence(
    readRevision: readRevision,
    newRevision: newRevision,
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

String _expectedMutation(String original) {
  final int match = original.indexOf(_originalFragment);
  if (match < 0) {
    throw StateError('The maintained mutation target is missing.');
  }
  if (original.indexOf(_originalFragment, match + _originalFragment.length) >=
      0) {
    throw StateError('The maintained mutation target is not unique.');
  }
  return original.replaceRange(
    match,
    match + _originalFragment.length,
    _replacementFragment,
  );
}

String _requiredEnvironment(String name) {
  final String? value = Platform.environment[name];
  if (value == null || value.trim().isEmpty) {
    throw StateError('$name is required for the OpenAI mutation live test.');
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

final class _MutationEvidence {
  const _MutationEvidence({
    required this.readRevision,
    required this.newRevision,
  });

  final String readRevision;
  final String newRevision;
}
