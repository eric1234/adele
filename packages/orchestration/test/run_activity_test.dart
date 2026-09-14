import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:test/test.dart';

void main() {
  test('activity values freeze caller lists and nested structured data', () {
    final Map<String, Object?> nested = {
      'list': <Object?>[
        {'value': 'original'},
      ],
    };
    final ToolOutcomeActivity outcome = ToolOutcomeActivity(
      disposition: ToolOutcomeDisposition.success,
      effectCertainty: EffectCertainty.knownOccurred,
      modelContent: 'Result',
      hostData: nested,
    );
    final ActivityFailure failure = ActivityFailure(
      kind: 'provider',
      message: 'Failed',
      providerDetails: nested,
    );
    final List<ToolActivityChange> changes = [
      ToolActivityChange(
        sequence: 8,
        kind: ToolActivityKind.completed,
        outcome: outcome,
      ),
    ];
    final ToolInvocationActivity tool = ToolInvocationActivity(
      id: ToolInvocationId('tool'),
      preparedSequence: 5,
      modelInvocationId: ModelInvocationId('model'),
      proposalSequence: 3,
      toolId: ToolId('test.tool'),
      alias: 'test',
      providerCallId: 'call',
      canonicalArguments: nested,
      changes: changes,
      outcome: outcome,
    );
    final ModelNativeEnvelope native = ModelNativeEnvelope(
      kind: 'opaque',
      compatibility: nested,
      data: nested,
    );
    final ModelOutputItem item = ModelNativeOutput(
      providerItemId: 'native',
      providerNativeMetadata: native,
    );
    final List<ModelOutputActivity> outputs = [
      ModelOutputActivity(sequence: 3, item: item),
    ];
    final ModelInvocationActivity model = ModelInvocationActivity(
      id: tool.modelInvocationId,
      startSequence: 2,
      outputs: outputs,
    );
    final List<RunLifecycleActivity> lifecycle = [
      const RunLifecycleActivity(sequence: 1, state: RunState.running),
    ];
    final List<ModelInvocationActivity> models = [model];
    final List<ToolInvocationActivity> tools = [tool];
    final List<RejectedToolProposalActivity> rejected = [
      RejectedToolProposalActivity(
        sequence: 9,
        modelInvocationId: model.id,
        proposalSequence: 4,
        proposal: ProviderToolProposal(
          providerCallId: 'rejected',
          alias: 'missing',
          arguments: nested,
        ),
        kind: ToolProposalFailureKind.unknownAlias,
        message: 'Missing tool',
      ),
    ];
    final RunActivitySnapshot snapshot = RunActivitySnapshot(
      runId: RunId('run'),
      sessionId: SessionId('session'),
      state: RunState.running,
      sequence: 9,
      lifecycle: lifecycle,
      models: models,
      tools: tools,
      rejectedProposals: rejected,
    );
    (nested['list']! as List<Object?>).clear();
    changes.clear();
    outputs.clear();
    lifecycle.clear();
    models.clear();
    tools.clear();
    rejected.clear();
    expect(snapshot.models.single.outputs.single.item, same(item));
    expect(snapshot.models.single.outputs.single.sequence, 3);
    expect(snapshot.tools.single.changes.single.outcome, same(outcome));
    expect(
      snapshot.rejectedProposals.single.proposal.arguments['list'],
      hasLength(1),
    );
    for (final List<Object?> list in <List<Object?>>[
      snapshot.lifecycle,
      snapshot.models,
      snapshot.tools,
      snapshot.rejectedProposals,
      tool.changes,
      model.outputs,
    ]) {
      expect(list.clear, throwsUnsupportedError);
    }
    for (final Map<String, Object?> map in [
      tool.canonicalArguments,
      outcome.hostData,
      failure.providerDetails,
      native.data,
      native.compatibility,
    ]) {
      expect(map.clear, throwsUnsupportedError);
      final List<Object?> list = map['list']! as List<Object?>;
      expect(list, hasLength(1));
      expect(list.clear, throwsUnsupportedError);
      expect(
        () => (list.single! as Map<String, Object?>)['value'] = 'changed',
        throwsUnsupportedError,
      );
    }
    expect(() => (outcome as dynamic).cause, throwsNoSuchMethodError);
    expect(() => (outcome as dynamic).hostDiagnostic, throwsNoSuchMethodError);
    expect(() => (failure as dynamic).cause, throwsNoSuchMethodError);
    expect(() => (tool as dynamic).executable, throwsNoSuchMethodError);
  });

  test('public model invocation IDs retain validation and value equality', () {
    expect(ModelInvocationId('m'), ModelInvocationId('m'));
    expect(ModelInvocationId('m').hashCode, ModelInvocationId('m').hashCode);
    expect(ModelInvocationId('m').toString(), 'm');
    for (final String invalid in ['', ' m', 'm ']) {
      expect(() => ModelInvocationId(invalid), throwsFormatException);
    }
  });
}
