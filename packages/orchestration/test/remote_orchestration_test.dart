import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration.dart';
import 'package:adele_product/adele_product.dart';
import 'package:test/test.dart';

void main() {
  test(
    'generated service names and authority-free materialization payload',
    () async {
      final service = _Service();
      final dispatcher = RemoteOrchestrationServiceDispatcher(service);
      addTearDown(dispatcher.close);
      final channel = _Channel(dispatcher);
      final client = RemoteOrchestrationServiceClient(channel);
      final session = Session(
        id: SessionId('session'),
        taskId: TaskId('task'),
        strategyId: OrchestrationStrategyId('dev.test.strategy'),
      );

      expect(remoteOrchestrationServiceId, 'orchestrationStrategy');
      expect(remoteOrchestrationHostServiceId, 'orchestrationExecutionHost');
      expect(
        await client.materialize(
          'route',
          RemoteOrchestrationSession.fromLocal(session),
          'run',
        ),
        'execution',
      );
      expect(channel.method, 'orchestrationStrategy.materialize');
      expect(channel.payload, {
        'routeId': 'route',
        'session': {
          'sessionId': 'session',
          'taskId': 'task',
          'strategyId': 'dev.test.strategy',
        },
        'runId': 'run',
      });
      expect(service.session!.toLocal().id, session.id);
      expect(service.session!.toLocal().taskId, session.taskId);
      expect(service.session!.toLocal().strategyId, session.strategyId);
      expect(
        await client.start('execution', 'fresh-start'),
        RemoteRunState.waiting,
      );
      expect(channel.payload, {
        'executionId': 'execution',
        'hostInvocationContext': 'fresh-start',
      });
      final resolution = ToolApprovalResolution(
        interruptionId: RunInterruptionId('interrupt'),
        toolInvocationId: ToolInvocationId('tool'),
        approved: false,
      );
      expect(
        await client.resolveApproval(
          'execution',
          RemoteApprovalResolution.fromLocal(resolution),
          'fresh-resume',
        ),
        RemoteRunState.completed,
      );
      expect(channel.payload, {
        'executionId': 'execution',
        'resolution': {
          'interruptionId': 'interrupt',
          'toolInvocationId': 'tool',
          'approved': false,
        },
        'hostInvocationContext': 'fresh-resume',
      });
      expect(service.resolution!.toLocal().approved, isFalse);
      await client.release('execution');
      expect(channel.payload, {'executionId': 'execution'});
    },
  );

  test(
    'all semantic input variants cross generated transport without causes',
    () async {
      final native = _native();
      final proposal = _proposal();
      final material = StrategyInferenceMaterial(
        instructions: '  exact instructions\n',
        input: [
          SemanticNativeInput(
            providerItemId: 'native-id',
            providerNativeMetadata: native,
          ),
          SemanticMessageInput(
            role: SemanticMessageRole.user,
            content: 'prompt',
          ),
          SemanticMessageInput(
            role: SemanticMessageRole.assistant,
            content: 'answer',
            providerItemId: 'message-id',
            providerNativeMetadata: native,
          ),
          SemanticToolProposalInput(
            proposal: proposal,
            providerItemId: 'proposal-id',
            providerNativeMetadata: native,
          ),
          for (final kind in ToolProposalFailureKind.values)
            SemanticToolProposalFailureInput(
              failure: ToolProposalFailure(
                kind: kind,
                providerCallId: 'call',
                alias: 'tool',
                message: 'safe diagnostic',
                cause: StateError('private cause'),
              ),
            ),
          for (final disposition in ToolOutcomeDisposition.values)
            SemanticToolOutcomeInput(
              providerCallId: 'call',
              outcome: ToolOutcome(
                disposition: disposition,
                failureKind: disposition == ToolOutcomeDisposition.failure
                    ? ToolFailureKind.infrastructure
                    : null,
                effectCertainty: EffectCertainty.uncertain,
                modelContent: 'model-visible outcome',
                hostData: {
                  'nested': [
                    {'value': 1},
                  ],
                },
                hostDiagnostic: 'diagnostic',
                cause: StateError('private cause'),
              ),
            ),
        ],
      );
      final host = _Host(_turn());
      final dispatcher = RemoteOrchestrationHostServiceDispatcher(host);
      addTearDown(dispatcher.close);
      final client = RemoteOrchestrationHostServiceClient(_Channel(dispatcher));
      await client.invokeModel(
        RemoteStrategyInferenceMaterial.fromLocal(material),
      );
      final restored = host.material!.toLocal();
      expect(restored.instructions, material.instructions);
      expect(
        restored.input.map((item) => item.runtimeType),
        material.input.map((item) => item.runtimeType),
      );
      for (int index = 0; index < material.input.length; index++) {
        expect(
          RemoteSemanticModelInput.fromLocal(restored.input[index]).payload,
          RemoteSemanticModelInput.fromLocal(material.input[index]).payload,
        );
      }
      expect(
        (restored.input.first as SemanticNativeInput)
            .providerNativeMetadata
            .data,
        native.data,
      );
      expect(
        (restored.input[3] as SemanticToolProposalInput).proposal.arguments,
        proposal.arguments,
      );
      for (final item
          in restored.input.whereType<SemanticToolProposalFailureInput>()) {
        expect(item.failure.cause, isNull);
      }
      for (final item in restored.input.whereType<SemanticToolOutcomeInput>()) {
        expect(item.outcome.cause, isNull);
        expect(item.outcome.hostDiagnostic, 'diagnostic');
      }
      expect(() => restored.input.clear(), throwsUnsupportedError);
    },
  );

  test(
    'ordered model output preserves native replay, safe presentation and full metadata',
    () async {
      final host = _Host(_turn());
      final dispatcher = RemoteOrchestrationHostServiceDispatcher(host);
      addTearDown(dispatcher.close);
      final channel = _Channel(dispatcher);
      final remote = await RemoteOrchestrationHostServiceClient(
        channel,
      ).invokeModel(_material());
      final tools = _Tools();
      final restored = remote.toLocal(tools: tools);
      expect(restored.tools, same(tools));
      expect(restored.output.map((item) => item.runtimeType), [
        ModelTextOutput,
        ModelNativeOutput,
        ModelToolProposalOutput,
        ModelTextOutput,
      ]);
      expect(remote.output[2].proposalHandle, 'proposal-handle');
      expect(remote.output.first.proposalHandle, isNull);
      expect(remote.toolSnapshotHandle, 'snapshot-handle');
      final native = restored.output[1] as ModelNativeOutput;
      expect(native.providerItemId, 'native-id');
      expect(native.providerNativeMetadata.kind, 'provider.native.v1');
      expect(native.providerNativeMetadata.compatibility, {
        'provider': 'opaque',
        'version': 2,
      });
      expect(native.providerNativeMetadata.data, {
        'encrypted': 'exact',
        'nested': [1, true, null, 1.5],
      });
      expect(native.presentation!.kind, 'provider.safe.v1');
      expect(native.presentation!.compactText, 'Safe summary');
      expect(native.presentation!.data, {
        'summary': ['one', 'two'],
      });
      final metadata = restored.metadata!;
      expect(metadata.effectiveModel, 'exact-model');
      expect(metadata.providerResponseId, 'response');
      expect(metadata.providerRequestId, 'request');
      expect(metadata.providerStopReason, 'opaque-stop');
      expect(
        metadata.providerNativeState!.data,
        native.providerNativeMetadata.data,
      );
      expect(metadata.usage!.inputTokens, 13);
      expect(metadata.usage!.outputTokens, 21);
      expect(metadata.usage!.cacheReadTokens, 5);
      expect(metadata.usage!.cacheWriteTokens, 8);
      expect(metadata.usage!.providerDetails, {
        'reasoning': 3,
        'nested': [true],
      });
      expect(restored.failure, isNull);
      expect(() => remote.output.clear(), throwsUnsupportedError);
      expect(() => remote.output[1].payload.clear(), throwsUnsupportedError);
    },
  );

  test(
    'settlements and bounded intentional failures remain distinct from RPC errors',
    () async {
      for (final settlement in ModelSettlement.values) {
        final turn = StrategyModelTurn.settled(
          tools: _Tools(),
          output: [],
          settlement: settlement,
          incompleteReason: settlement == ModelSettlement.incomplete
              ? ModelIncompleteReason.contextLimit
              : null,
        );
        final remote = RemoteStrategyModelTurn.fromLocal(
          turn,
          toolSnapshotHandle: 'tools',
          proposalHandle: (_) => 'unused',
        );
        final restored = remote.toLocal(tools: _Tools());
        expect(restored.settlement, settlement);
        expect(restored.incompleteReason, turn.incompleteReason);
      }
      final failure = RemoteOrchestrationFailure.fromLocal(
        StateError('x' * 5000),
      );
      expect(failure.code, 'StateError');
      expect(failure.message.length, 4096);
      expect(failure.toLocal(), isA<RemoteStrategyFailure>());
      expect(
        RemoteOrchestrationFailure.fromLocal(failure.toLocal()).message,
        failure.message,
      );
      final failed = RemoteStrategyModelTurn.fromLocal(
        StrategyModelTurn.failed(
          tools: _Tools(),
          output: [ModelTextOutput('partial')],
          error: failure.toLocal(),
        ),
        toolSnapshotHandle: 'tools',
        proposalHandle: (_) => 'unused',
      ).toLocal(tools: _Tools());
      expect(failed.settlement, isNull);
      expect(failed.metadata, isNull);
      expect(failed.output, hasLength(1));
      expect(failed.failure, isA<RemoteStrategyFailure>());
      const rpcError = _Failure();
      final host = _Host(_turn())..failure = rpcError;
      final dispatcher = RemoteOrchestrationHostServiceDispatcher(host);
      addTearDown(dispatcher.close);
      await expectLater(
        RemoteOrchestrationHostServiceClient(
          _Channel(dispatcher),
        ).invokeModel(_material()),
        throwsA(isA<AdeleRemoteFailure>()),
      );
    },
  );

  for (final error in <Object>[
    const _Failure(),
    AdeleProtocolException('malformed provider data: ${'x' * 5000}'),
  ]) {
    test(
      'collected ${error.runtimeType} preserves partial model output',
      () async {
        final original = _turn();
        final host = _Host(
          StrategyModelTurn.failed(
            tools: original.tools,
            output: original.output,
            error: error,
          ),
        );
        final dispatcher = RemoteOrchestrationHostServiceDispatcher(host);
        addTearDown(dispatcher.close);
        final remote = await RemoteOrchestrationHostServiceClient(
          _Channel(dispatcher),
        ).invokeModel(_material());
        final restored = remote.toLocal(tools: _Tools());
        expect(restored.settlement, isNull);
        expect(restored.metadata, isNull);
        final failure = restored.failure! as RemoteStrategyFailure;
        expect(failure.code, error.runtimeType.toString());
        expect(
          failure.message,
          error.toString().substring(
            0,
            error.toString().length > 4096 ? 4096 : error.toString().length,
          ),
        );
        expect(failure.message.length, lessThanOrEqualTo(4096));
        expect(
          restored.output.map((item) => item.runtimeType),
          original.output.map((item) => item.runtimeType),
        );
        for (int index = 0; index < original.output.length; index++) {
          expect(
            RemoteModelOutput.fromLocal(restored.output[index]).payload,
            RemoteModelOutput.fromLocal(original.output[index]).payload,
          );
        }
      },
    );
  }

  test(
    'tool waiting/continuation and field-free current approval roundtrip',
    () async {
      final host = _Host(_turn());
      final dispatcher = RemoteOrchestrationHostServiceDispatcher(host);
      addTearDown(dispatcher.close);
      final channel = _Channel(dispatcher);
      final client = RemoteOrchestrationHostServiceClient(channel);
      expect(
        (await client.processProposal('tools', 'proposal')).toLocal(),
        isA<StrategyToolWaiting>(),
      );
      host.result = StrategyToolContinuation(_outcome());
      final result =
          (await client.processProposal('tools', 'proposal')).toLocal()
              as StrategyToolContinuation;
      expect(result.item, isA<SemanticToolOutcomeInput>());
      expect(
        (await client.applyCurrentApproval()).toLocal(),
        isA<SemanticToolOutcomeInput>(),
      );
      expect(channel.method, 'orchestrationExecutionHost.applyCurrentApproval');
      expect(channel.payload, isEmpty);
      expect(
        await client.transition(
          RemoteRunTransition.fail,
          RemoteOrchestrationFailure.fromLocal(StateError('intentional')),
        ),
        RemoteRunState.failed,
      );
    },
  );

  test(
    'payload snapshots recursively freeze and reject unsupported structures',
    () {
      final nested = <Object?>[1];
      final arguments = <String, Object?>{'nested': nested};
      final remote = RemoteModelOutput(
        kind: RemoteModelOutputKind.toolProposal,
        proposalHandle: 'proposal',
        payload: {
          'providerItemId': null,
          'providerNativeMetadata': null,
          'proposal': {
            'providerCallId': 'call',
            'alias': 'tool',
            'arguments': arguments,
          },
        },
      );
      nested.add(2);
      arguments['new'] = true;
      final restored =
          (remote.toLocal() as ModelToolProposalOutput).proposal.arguments;
      expect(restored, {
        'nested': [1],
      });
      expect(
        () => (restored['nested']! as List).add(3),
        throwsUnsupportedError,
      );
      final cycle = <String, Object?>{};
      cycle['cycle'] = cycle;
      for (final value in [Object(), double.infinity, cycle]) {
        expect(
          () => RemoteModelOutput(
            kind: RemoteModelOutputKind.toolProposal,
            proposalHandle: null,
            payload: {
              'providerItemId': null,
              'providerNativeMetadata': null,
              'proposal': {
                'providerCallId': 'call',
                'alias': 'tool',
                'arguments': {'bad': value},
              },
            },
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('strict semantic kinds, payload fields, enums and native shapes', () {
    for (final payload in <Map<String, Object?>>[
      {'role': 'user', 'content': 'missing nullable keys'},
      {
        'role': 'system',
        'content': 'text',
        'providerItemId': null,
        'providerNativeMetadata': null,
      },
      {
        'role': 'user',
        'content': '',
        'providerItemId': null,
        'providerNativeMetadata': null,
      },
      {
        'role': 'user',
        'content': 'text',
        'providerItemId': null,
        'providerNativeMetadata': null,
        'extra': 1,
      },
      {
        'role': 'user',
        'content': 'text',
        'providerItemId': 1,
        'providerNativeMetadata': null,
      },
      {
        'role': 'user',
        'content': 'text',
        'providerItemId': null,
        'providerNativeMetadata': {
          'kind': 'native',
          'data': <String, Object?>{},
        },
      },
    ]) {
      expect(
        () => RemoteSemanticModelInput(
          kind: RemoteSemanticModelInputKind.message,
          payload: payload,
        ),
        throwsFormatException,
      );
    }
    expect(
      () => RemoteModelOutput.fromLocal(
        ModelTextOutput('text'),
        proposalHandle: 'forged',
      ),
      throwsFormatException,
    );
    expect(
      () => RemoteStrategyToolResult(
        kind: RemoteStrategyToolResultKind.waiting,
        item: RemoteSemanticModelInput.fromLocal(_outcome()),
      ),
      throwsFormatException,
    );
    expect(
      () => RemoteStrategyModelTurn(
        toolSnapshotHandle: 'tools',
        output: [],
        settlement: RemoteModelSettlement.incomplete,
        incompleteReason: null,
        metadata: RemoteModelTerminalMetadata.fromLocal(
          ModelTerminalMetadata(),
        ),
        failure: null,
      ),
      throwsFormatException,
    );
    expect(
      () => RemoteStrategyModelTurn.fromLocal(
        StrategyModelTurn.settled(
          tools: _Tools(),
          output: [
            ModelToolProposalOutput(_proposal()),
            ModelToolProposalOutput(_proposal()),
          ],
        ),
        toolSnapshotHandle: 'tools',
        proposalHandle: (_) => 'duplicate',
      ),
      throwsFormatException,
    );
    expect(
      () => RemoteApprovalResolution(
        interruptionId: '',
        toolInvocationId: 'tool',
        approved: true,
      ),
      throwsFormatException,
    );
    expect(
      () => RemoteOrchestrationFailure(code: 'x' * 129, message: 'bounded'),
      throwsFormatException,
    );
  });

  test(
    'generated decoder contains constructor failures and malformed enum wire data',
    () async {
      final host = _Host(_turn());
      final dispatcher = RemoteOrchestrationHostServiceDispatcher(host);
      addTearDown(dispatcher.close);
      final channel = _Channel(dispatcher);
      await RemoteOrchestrationHostServiceClient(
        channel,
      ).invokeModel(_material());
      final valid = Map<String, Object?>.from(channel.response! as Map);
      for (final mutation in <Map<String, Object?>>[
        {...valid, 'settlement': 'not-a-settlement'},
        {...valid, 'incompleteReason': 'outputLimit'},
        {...valid, 'metadata': null},
        {...valid, 'extra': true},
        {...valid}..remove('failure'),
        {
          ...valid,
          'output': [
            {
              'kind': 'unknown',
              'payload': <String, Object?>{},
              'proposalHandle': null,
            },
          ],
        },
        {
          ...valid,
          'output': [
            {
              'kind': 'text',
              'payload': {'content': 'missing keys'},
              'proposalHandle': null,
            },
          ],
        },
      ]) {
        await expectLater(
          RemoteOrchestrationHostServiceClient(
            _ResponseChannel(mutation),
          ).invokeModel(_material()),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
    },
  );

  test(
    'generated dispatch rejects authority selectors and missing parameters',
    () async {
      final service = _Service();
      final dispatcher = RemoteOrchestrationServiceDispatcher(service);
      addTearDown(dispatcher.close);
      for (final payload in <Map<String, Object?>>[
        {'routeId': 'route', 'runId': 'run'},
        {
          'routeId': 'route',
          'runId': 'run',
          'session': {
            'sessionId': 'session',
            'taskId': 'task',
            'strategyId': 'dev.test.strategy',
          },
          'hostInvocationContext': 'not-allowed',
        },
        {
          'routeId': 'route',
          'runId': 'run',
          'session': {
            'sessionId': 'session',
            'taskId': 'task',
            'strategyId': 'dev.test.strategy',
            'environmentId': 'not-allowed',
          },
        },
      ]) {
        final response = await dispatcher.dispatch({
          'kind': 'request',
          'requestId': 1,
          'method': remoteOrchestrationServiceMaterializeId,
          'payload': payload,
        });
        expect((response['error']! as Map)['code'], 'invalid_request');
      }
      expect(service.session, isNull);
      final host = _Host(_turn());
      final hostDispatcher = RemoteOrchestrationHostServiceDispatcher(host);
      addTearDown(hostDispatcher.close);
      final response = await hostDispatcher.dispatch({
        'kind': 'request',
        'requestId': 1,
        'method': remoteOrchestrationHostServiceApplyCurrentApprovalId,
        'payload': {'approved': true},
      });
      expect((response['error']! as Map)['code'], 'invalid_request');
    },
  );
}

ModelNativeEnvelope _native() => ModelNativeEnvelope(
  kind: 'provider.native.v1',
  compatibility: {'provider': 'opaque', 'version': 2},
  data: {
    'encrypted': 'exact',
    'nested': [1, true, null, 1.5],
  },
);

ProviderToolProposal _proposal() => ProviderToolProposal(
  providerCallId: 'call',
  alias: 'tool',
  arguments: {
    'nested': [
      {'value': true},
    ],
  },
);

SemanticToolOutcomeInput _outcome() => SemanticToolOutcomeInput(
  providerCallId: 'call',
  outcome: ToolOutcome(
    disposition: ToolOutcomeDisposition.success,
    effectCertainty: EffectCertainty.knownOccurred,
    modelContent: 'result',
  ),
);

RemoteStrategyInferenceMaterial _material() =>
    RemoteStrategyInferenceMaterial(instructions: '', input: []);

StrategyModelTurn _turn() => StrategyModelTurn.settled(
  tools: _Tools(),
  output: [
    ModelTextOutput(
      'before',
      providerItemId: 'text-id',
      providerNativeMetadata: _native(),
    ),
    ModelNativeOutput(
      providerItemId: 'native-id',
      providerNativeMetadata: _native(),
      presentation: ModelNativePresentation(
        kind: 'provider.safe.v1',
        compactText: 'Safe summary',
        data: {
          'summary': ['one', 'two'],
        },
      ),
    ),
    ModelToolProposalOutput(
      _proposal(),
      providerItemId: 'proposal-id',
      providerNativeMetadata: _native(),
    ),
    ModelTextOutput('after'),
  ],
  metadata: ModelTerminalMetadata(
    effectiveModel: 'exact-model',
    providerResponseId: 'response',
    providerRequestId: 'request',
    providerStopReason: 'opaque-stop',
    providerNativeState: _native(),
    usage: ModelUsage(
      inputTokens: 13,
      outputTokens: 21,
      cacheReadTokens: 5,
      cacheWriteTokens: 8,
      providerDetails: {
        'reasoning': 3,
        'nested': [true],
      },
    ),
  ),
);

final class _Tools implements StrategyToolSnapshot {}

final class _Service implements RemoteOrchestrationService {
  RemoteOrchestrationSession? session;
  RemoteApprovalResolution? resolution;
  @override
  Future<String> materialize(
    String routeId,
    RemoteOrchestrationSession session,
    String runId,
  ) async {
    this.session = session;
    return 'execution';
  }

  @override
  Future<RemoteRunState> start(
    String executionId,
    String hostInvocationContext,
  ) async => RemoteRunState.waiting;
  @override
  Future<RemoteRunState> resolveApproval(
    String executionId,
    RemoteApprovalResolution resolution,
    String hostInvocationContext,
  ) async {
    this.resolution = resolution;
    return RemoteRunState.completed;
  }

  @override
  Future<void> release(String executionId) async {}
}

final class _Host implements RemoteOrchestrationHostService {
  _Host(this.turn);
  final StrategyModelTurn turn;
  RemoteStrategyInferenceMaterial? material;
  StrategyToolResult result = const StrategyToolWaiting();
  Object? failure;
  @override
  Future<RemoteRunState> transition(
    RemoteRunTransition transition,
    RemoteOrchestrationFailure? failure,
  ) async => RemoteRunState.values.byName(switch (transition) {
    RemoteRunTransition.start => 'running',
    RemoteRunTransition.complete => 'completed',
    RemoteRunTransition.fail => 'failed',
  });
  @override
  Future<RemoteStrategyModelTurn> invokeModel(
    RemoteStrategyInferenceMaterial material,
  ) async {
    if (failure != null) throw failure!;
    this.material = material;
    return RemoteStrategyModelTurn.fromLocal(
      turn,
      toolSnapshotHandle: 'snapshot-handle',
      proposalHandle: (_) => 'proposal-handle',
    );
  }

  @override
  Future<RemoteStrategyToolResult> processProposal(
    String toolSnapshotHandle,
    String proposalHandle,
  ) async => RemoteStrategyToolResult.fromLocal(result);
  @override
  Future<RemoteSemanticModelInput> applyCurrentApproval() async =>
      RemoteSemanticModelInput.fromLocal(_outcome());
}

final class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
  String? method;
  Map<String, Object?>? payload;
  Object? response;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    this.payload = payload;
    final result = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': 1,
      'method': method,
      'payload': payload,
    });
    if (result['ok'] != true) throw const _Failure();
    return response = result['payload'];
  }
}

final class _ResponseChannel implements AdeleRequestChannel {
  _ResponseChannel(this.response);
  final Object? response;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      response;
}

final class _Failure implements AdeleRemoteFailure {
  const _Failure();
  @override
  String get code => 'internal_error';
  @override
  String get message => 'RPC failed';
  @override
  String? get declaredFailureType => null;
  @override
  Map<String, Object?> get details => const {};
}
