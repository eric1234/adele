import 'dart:convert';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration.dart';
import 'package:adele_product/adele_product.dart';
import 'package:test/test.dart';

void main() {
  for (final state in [
    RunState.completed,
    RunState.failed,
    RunState.cancelled,
    RunState.running,
    RunState.waiting,
  ]) {
    test('$state preserves semantic evidence and original provenance', () {
      final original = _richActivity(state: state);
      final history = _project(original);
      final restored = HistoricalRunEvidence.fromJson(_copy(history.toJson()));
      expect(restored.toJson(), history.toJson());
      expect(restored.status, history.status);
      if (history.status == HistoricalRunStatus.terminal) {
        expect(restored.record!.id, original.runId);
        expect(restored.record!.sessionId, original.sessionId);
        expect(restored.record!.state.name, state.name);
      } else {
        expect(restored.record, isNull);
      }
      final activity = restored.activity;
      expect(activity.state, state);
      expect(activity.sequence, 90);
      expect(
        activity.lifecycle.map((item) => (item.sequence, item.state)),
        original.lifecycle.map((item) => (item.sequence, item.state)),
      );
      final model = activity.models.first;
      expect(model.id, ModelInvocationId('model'));
      expect(model.startSequence, 2);
      expect(model.terminalSequence, 12);
      expect(model.settlement, ModelSettlement.completed);
      expect(model.outputs.map((item) => item.sequence), [
        3,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
      ]);
      expect(
        (model.outputs.first.item as ModelTextOutput).content,
        'Exact\r\ntext',
      );
      expect(
        (model.outputs.first.item as ModelTextOutput).providerItemId,
        'text-id',
      );
      for (var index = 0; index < activity.tools.length; index++) {
        final tool = activity.tools[index];
        final source = original.tools[index];
        final output = model.outputs[index + 1];
        final proposal = output.item as ModelToolProposalOutput;
        expect(proposal.providerItemId, 'proposal-$index');
        expect(proposal.proposal.providerCallId, 'call-$index');
        expect(proposal.proposal.alias, 'tool');
        expect(proposal.proposal.arguments, {
          'path': './original',
          'nested': [index, true, null, 1.5],
        });
        expect(tool.id, source.id);
        expect(tool.preparedSequence, source.preparedSequence);
        expect(tool.modelInvocationId, model.id);
        expect(tool.proposalSequence, output.sequence);
        expect(tool.toolId, ToolId('test.tool'));
        expect(tool.alias, proposal.proposal.alias);
        expect(tool.providerCallId, proposal.proposal.providerCallId);
        expect(tool.canonicalArguments, {
          'path': 'normalized',
          'nested': [index, true, null, 1.5],
        });
        expect(tool.canonicalArguments, isNot(proposal.proposal.arguments));
        expect(tool.effects!.effects, {ToolEffect.sourceMutation});
        expect(tool.effects!.targets.single.uri, Uri.parse('file:///target'));
        expect(tool.effects!.summary, 'Change target');
        expect(tool.effects!.uncertainty, EffectUncertainty.uncertain);
        expect(
          tool.changes.map((change) => (change.sequence, change.kind)),
          source.changes.map((change) => (change.sequence, change.kind)),
        );
        for (
          var changeIndex = 0;
          changeIndex < tool.changes.length;
          changeIndex++
        ) {
          final change = tool.changes[changeIndex];
          final expected = source.changes[changeIndex];
          expect(change.policyDecision, expected.policyDecision);
          expect(change.interruptionId, expected.interruptionId);
          expect(change.approved, expected.approved);
          expect(change.effects?.summary, expected.effects?.summary);
          expect(change.progress?.kind, expected.progress?.kind);
          expect(change.progress?.content, expected.progress?.content);
          _expectOutcome(change.outcome, expected.outcome);
        }
        _expectOutcome(tool.outcome, source.outcome);
      }
      final approved = activity.tools[0];
      expect(approved.changes.map((item) => item.kind), [
        ToolActivityKind.prepared,
        ToolActivityKind.policyEvaluated,
        ToolActivityKind.approvalRequested,
        ToolActivityKind.approvalResolved,
        ToolActivityKind.executionStarted,
        ToolActivityKind.progress,
        ToolActivityKind.completed,
      ]);
      expect(
        approved.changes[1].policyDecision,
        ToolActivityPolicyDecision.ask,
      );
      expect(approved.changes[3].approved, isTrue);
      expect(approved.changes[5].progress!.content, 'Public progress');
      for (final tool in [activity.tools[1], activity.tools[2]]) {
        expect(
          tool.changes.map((item) => item.kind),
          isNot(contains(ToolActivityKind.executionStarted)),
        );
        expect(tool.outcome!.effectCertainty, EffectCertainty.knownNotOccurred);
      }
      expect(
        activity.tools[1].outcome!.disposition,
        ToolOutcomeDisposition.policyDenied,
      );
      expect(
        activity.tools[1].changes[1].policyDecision,
        ToolActivityPolicyDecision.deny,
      );
      expect(
        activity.tools[2].outcome!.disposition,
        ToolOutcomeDisposition.userRejected,
      );
      expect(activity.tools[2].changes[3].approved, isFalse);
      expect(
        activity.tools[3].outcome!.disposition,
        ToolOutcomeDisposition.failure,
      );
      expect(
        activity.tools[3].outcome!.failureKind,
        ToolFailureKind.infrastructure,
      );
      expect(
        activity.tools[3].outcome!.effectCertainty,
        EffectCertainty.knownOccurred,
      );
      expect(
        activity.tools[4].outcome!.disposition,
        ToolOutcomeDisposition.indeterminate,
      );
      expect(
        activity.tools[4].outcome!.effectCertainty,
        EffectCertainty.uncertain,
      );
      final unfinished = activity.tools[5];
      expect(unfinished.changes.last.kind, ToolActivityKind.executionStarted);
      expect(unfinished.outcome, isNull);
      expect(
        unfinished.changes.every((change) => change.outcome == null),
        isTrue,
      );

      final rejection = activity.rejectedProposals.single;
      expect(rejection.sequence, 78);
      expect(rejection.modelInvocationId, model.id);
      expect(rejection.proposalSequence, 11);
      expect(rejection.proposal.providerCallId, 'call-6');
      expect(
        rejection.proposal.arguments,
        (model.outputs.last.item as ModelToolProposalOutput).proposal.arguments,
      );
      expect(rejection.kind, ToolProposalFailureKind.unknownAlias);
      expect(rejection.message, 'Unknown tool');
      expect(
        activity.tools.any((tool) => tool.providerCallId == 'call-6'),
        isFalse,
      );
      final incomplete = activity.models[1];
      expect(incomplete.terminalSequence, 83);
      expect(incomplete.settlement, ModelSettlement.incomplete);
      expect(incomplete.incompleteReason, ModelIncompleteReason.outputLimit);
      expect(
        (incomplete.outputs.single.item as ModelTextOutput).content,
        'Partial',
      );
      final missingTerminal = activity.models[2];
      expect(missingTerminal.terminalSequence, isNull);
      expect(missingTerminal.settlement, isNull);
      expect(missingTerminal.incompleteReason, isNull);
      expect(missingTerminal.failure, isNull);
      expect(
        (missingTerminal.outputs.single.item as ModelTextOutput).content,
        'Unsettled',
      );
      final failed = activity.models[3];
      expect(failed.terminalSequence, 88);
      expect(failed.settlement, isNull);
      expect(failed.failure!.kind, 'provider');
      expect(failed.failure!.message, 'Model failed');
      expect(failed.failure!.providerCode, 'provider-code');
      if (state == RunState.failed) {
        expect(activity.failure!.kind, 'strategy');
        expect(activity.failure!.message, 'Run failed');
        expect(activity.failure!.providerCode, 'run-code');
      } else {
        expect(activity.failure, isNull);
      }
    });
  }

  for (final state in [RunState.running, RunState.waiting]) {
    test(
      '$state interrupted prefix preserves missing outcomes and approvals',
      () {
        final original = _interruptedActivity(state);
        final history = HistoricalRunEvidence.fromActivity(
          status: HistoricalRunStatus.interrupted,
          record: null,
          activity: original,
        );
        for (final value in [
          history,
          HistoricalRunEvidence.fromJson(_copy(history.toJson())),
        ]) {
          expect(value.status, HistoricalRunStatus.interrupted);
          expect(value.record, isNull);
          expect(value.toJson()['status'], 'interrupted');
          expect(value.toJson().containsKey('record'), isTrue);
          expect(value.toJson()['record'], isNull);
          expect(value.activity.runId, original.runId);
          expect(value.activity.sessionId, original.sessionId);
          expect(value.activity.state, state);
          expect(value.activity.sequence, original.sequence);
          expect(value.activity.lifecycle.last.state, state);
          expect(value.activity.failure, isNull);
          final tool = value.activity.tools.single;
          expect(tool.outcome, isNull);
          expect(
            tool.changes.every((change) => change.outcome == null),
            isTrue,
          );
          expect(
            tool.changes.last.kind,
            state == RunState.waiting
                ? ToolActivityKind.approvalRequested
                : ToolActivityKind.progress,
          );
          expect(
            tool.changes[2].interruptionId,
            RunInterruptionId('approval-0'),
          );
          if (state == RunState.waiting) {
            expect(
              tool.changes.every((change) => change.approved == null),
              isTrue,
            );
            expect(
              tool.changes.map((change) => change.kind),
              isNot(contains(ToolActivityKind.executionStarted)),
            );
          } else {
            expect(tool.changes[3].approved, isTrue);
            expect(tool.changes.last.progress!.content, 'Public progress');
          }
          expect(
            value.activity.models.single.outputs.map(
              (output) => output.sequence,
            ),
            [3, 5, 6, 7, 8, 9, 10, 11],
          );
        }
      },
    );
  }

  test(
    'interrupted created and unsettled model evidence invent no terminal',
    () {
      final source = _richActivity();
      for (final activity in [
        RunActivitySnapshot(
          runId: source.runId,
          sessionId: source.sessionId,
          state: RunState.created,
          sequence: 0,
        ),
        RunActivitySnapshot(
          runId: source.runId,
          sessionId: source.sessionId,
          state: RunState.running,
          sequence: 85,
          lifecycle: [
            const RunLifecycleActivity(sequence: 1, state: RunState.running),
          ],
          models: [source.models[2]],
        ),
      ]) {
        final history = HistoricalRunEvidence.fromJson(
          _copy(_project(activity).toJson()),
        );
        expect(history.status, HistoricalRunStatus.interrupted);
        expect(history.record, isNull);
        expect(history.activity.state, activity.state);
        expect(history.activity.failure, isNull);
        expect(history.activity.tools, isEmpty);
        for (final model in history.activity.models) {
          expect(model.terminalSequence, isNull);
          expect(model.settlement, isNull);
          expect(model.failure, isNull);
          expect(
            (model.outputs.single.item as ModelTextOutput).content,
            'Unsettled',
          );
        }
      }
    },
  );

  test('native and JSON status, record and activity shapes must agree', () {
    final valid = _project(
      RunActivitySnapshot(
        runId: RunId('history'),
        sessionId: SessionId('session'),
        state: RunState.created,
        sequence: 0,
      ),
    ).toJson();
    for (final status in HistoricalRunStatus.values) {
      for (final state in RunState.values) {
        for (final terminalState in [null, ...RunTerminalState.values]) {
          final record = terminalState == null
              ? null
              : RunRecord(
                  id: RunId('history'),
                  sessionId: SessionId('session'),
                  state: terminalState,
                );
          final activity = RunActivitySnapshot(
            runId: RunId('history'),
            sessionId: SessionId('session'),
            state: state,
            sequence: 0,
          );
          final json = _copy(valid)
            ..['status'] = status.name
            ..['state'] = state.name
            ..['record'] = record == null
                ? null
                : {
                    'id': record.id.value,
                    'sessionId': record.sessionId.value,
                    'state': record.state.name,
                  };
          final accepts = status == HistoricalRunStatus.terminal
              ? terminalState?.name == state.name
              : terminalState == null &&
                    [
                      RunState.created,
                      RunState.running,
                      RunState.waiting,
                    ].contains(state);
          for (final construct in [
            () => HistoricalRunEvidence.fromActivity(
              status: status,
              record: record,
              activity: activity,
            ),
            () => HistoricalRunEvidence.fromJson(json),
          ]) {
            if (accepts) {
              final history = construct();
              expect(history.status, status);
              expect(history.record?.state, terminalState);
              expect(history.activity.state, state);
            } else {
              expect(
                construct,
                throwsFormatException,
                reason: '$status / $terminalState / $state',
              );
            }
          }
        }
      }
    }
    final terminal = _project(_richActivity());
    expect(
      HistoricalRunEvidence.fromActivity(
        record: terminal.record,
        activity: terminal.activity,
      ).status,
      HistoricalRunStatus.terminal,
    );
    expect(
      () => HistoricalRunEvidence.fromActivity(
        record: null,
        activity: _interruptedActivity(RunState.running),
      ),
      throwsFormatException,
    );
  });

  for (final state in [RunState.running, RunState.waiting]) {
    test(
      '$state interrupted contradictions fail native, JSON and remote reads',
      () async {
        final source = _richActivity(state: state);
        final valid = _project(source).toJson();
        for (final (label, lifecycle, failure)
            in <(String, List<RunLifecycleActivity>, ActivityFailure?)>[
              for (final terminalState in [
                RunState.completed,
                RunState.failed,
                RunState.cancelled,
              ])
                (
                  'hidden $terminalState',
                  [
                    RunLifecycleActivity(sequence: 1, state: terminalState),
                    RunLifecycleActivity(sequence: 90, state: state),
                  ],
                  null,
                ),
              (
                'mismatched latest sequence',
                [
                  RunLifecycleActivity(
                    sequence: 90,
                    state: state == RunState.running
                        ? RunState.waiting
                        : RunState.running,
                  ),
                  RunLifecycleActivity(sequence: 1, state: state),
                ],
                null,
              ),
              (
                'Run failure',
                source.lifecycle,
                ActivityFailure(kind: 'strategy', message: 'Run failed'),
              ),
            ]) {
          final activity = RunActivitySnapshot(
            runId: source.runId,
            sessionId: source.sessionId,
            state: state,
            sequence: source.sequence,
            lifecycle: lifecycle,
            models: source.models,
            tools: source.tools,
            rejectedProposals: source.rejectedProposals,
            failure: failure,
          );
          final json = _copy(valid)
            ..['lifecycle'] = [
              for (final item in lifecycle)
                {'sequence': item.sequence, 'state': item.state.name},
            ]
            ..['failure'] = failure == null
                ? null
                : {
                    'kind': failure.kind,
                    'message': failure.message,
                    'providerCode': null,
                  };
          expect(
            () => _project(activity),
            throwsFormatException,
            reason: label,
          );
          expect(
            () => HistoricalRunEvidence.fromJson(json),
            throwsFormatException,
            reason: label,
          );
          await expectLater(
            RemoteOrchestrationHostServiceClient(
              _ResponseChannel({'payload': json}),
            ).readHistoricalRun('history'),
            throwsA(isA<AdeleProtocolException>()),
            reason: label,
          );
        }
      },
    );
    test(
      '$state latest lifecycle uses occurrence sequence, not list order',
      () async {
        final source = _interruptedActivity(state);
        final json = _copy(_project(source).toJson());
        json['lifecycle'] = (json['lifecycle'] as List).reversed.toList();
        final native = _project(
          RunActivitySnapshot(
            runId: source.runId,
            sessionId: source.sessionId,
            state: state,
            sequence: source.sequence,
            lifecycle: source.lifecycle.reversed,
            models: source.models,
            tools: source.tools,
          ),
        );
        final remote = await RemoteOrchestrationHostServiceClient(
          _ResponseChannel({'payload': json}),
        ).readHistoricalRun('history');
        for (final history in [
          native,
          HistoricalRunEvidence.fromJson(json),
          remote.toLocal(),
        ]) {
          expect(history.activity.state, state);
          expect(history.activity.lifecycle.first.state, state);
          expect(history.activity.lifecycle.last.state, RunState.running);
          expect(history.toJson(), json);
        }
      },
    );
  }

  test(
    'created interrupted history rejects every observed field and nonzero sequence',
    () async {
      final source = _richActivity();
      final sourceJson = _project(source).toJson();
      final empty = _project(
        RunActivitySnapshot(
          runId: source.runId,
          sessionId: source.sessionId,
          state: RunState.created,
          sequence: 0,
        ),
      ).toJson();
      for (final field in [
        'sequence',
        'lifecycle',
        'models',
        'tools',
        'rejectedProposals',
        'failure',
      ]) {
        final activity = RunActivitySnapshot(
          runId: source.runId,
          sessionId: source.sessionId,
          state: RunState.created,
          sequence: field == 'sequence' ? 1 : 0,
          lifecycle: field == 'lifecycle'
              ? [
                  const RunLifecycleActivity(
                    sequence: 0,
                    state: RunState.created,
                  ),
                ]
              : [],
          models: field == 'models' ? source.models : [],
          tools: field == 'tools' ? source.tools : [],
          rejectedProposals: field == 'rejectedProposals'
              ? source.rejectedProposals
              : [],
          failure: field == 'failure' ? source.failure : null,
        );
        final json = _copy(empty)
          ..[field] = switch (field) {
            'sequence' => 1,
            'lifecycle' => [
              {'sequence': 0, 'state': 'created'},
            ],
            _ => sourceJson[field],
          };
        expect(() => _project(activity), throwsFormatException, reason: field);
        expect(
          () => HistoricalRunEvidence.fromJson(json),
          throwsFormatException,
          reason: field,
        );
        await expectLater(
          RemoteOrchestrationHostServiceClient(
            _ResponseChannel({'payload': json}),
          ).readHistoricalRun('history'),
          throwsA(isA<AdeleProtocolException>()),
          reason: field,
        );
      }
    },
  );

  test('JSON rejects malformed status/record and contradictory identities', () {
    final valid = _project(_richActivity()).toJson();
    for (final (path, key, replacement) in <(List<Object>, String, Object?)>[
      for (final status in [
        null,
        1,
        true,
        <String, Object?>{},
        <Object?>[],
        'running',
        'unknown',
      ])
        ([], 'status', status),
      for (final record in [
        null,
        1,
        true,
        '',
        <String, Object?>{},
        <Object?>[],
      ])
        ([], 'record', record),
      ([], 'runId', 'other'),
      ([], 'sessionId', 'other'),
      ([], 'state', 'completed'),
      (['record'], 'id', 'other'),
      (['record'], 'sessionId', 'other'),
      (['record'], 'state', 'completed'),
      (['record'], 'state', 'running'),
      (['record'], 'state', 'unknown'),
      (['record'], 'state', null),
      (['record'], 'id', 1),
      (['record'], 'sessionId', null),
    ]) {
      final value = _copy(valid);
      _at(value, path)[key] = replacement;
      expect(
        () => HistoricalRunEvidence.fromJson(value),
        throwsFormatException,
        reason: '$path.$key = $replacement',
      );
    }
    for (final (path, fields) in <(List<Object>, List<String>)>[
      ([], ['status', 'record', 'runId', 'sessionId', 'state']),
      (['record'], ['id', 'sessionId', 'state']),
    ]) {
      for (final field in fields) {
        final value = _copy(valid);
        _at(value, path).remove(field);
        expect(
          () => HistoricalRunEvidence.fromJson(value),
          throwsFormatException,
        );
      }
    }
  });

  test('empty terminal evidence is valid and differs from a failed read', () {
    for (final state in RunTerminalState.values) {
      final activity = RunActivitySnapshot(
        runId: RunId('empty'),
        sessionId: SessionId('session'),
        state: RunState.values.byName(state.name),
        sequence: 0,
      );
      final history = _project(activity);
      expect(history.status, HistoricalRunStatus.terminal);
      expect(history.record!.state, state);
      expect(history.activity.models, isEmpty);
      expect(history.activity.tools, isEmpty);
      expect(history.activity.rejectedProposals, isEmpty);
      expect(history.activity.failure, isNull);
      expect(
        HistoricalRunEvidence.fromJson(_copy(history.toJson())).toJson(),
        history.toJson(),
      );
    }
  });

  test(
    'record and activity identity, Session and terminal state must agree',
    () {
      final activity = _richActivity();
      for (final record in [
        RunRecord(
          id: RunId('other'),
          sessionId: activity.sessionId,
          state: RunTerminalState.failed,
        ),
        RunRecord(
          id: activity.runId,
          sessionId: SessionId('other'),
          state: RunTerminalState.failed,
        ),
        RunRecord(
          id: activity.runId,
          sessionId: activity.sessionId,
          state: RunTerminalState.completed,
        ),
      ]) {
        expect(
          () => HistoricalRunEvidence.fromActivity(
            record: record,
            activity: activity,
          ),
          throwsFormatException,
        );
      }
    },
  );

  for (final state in [RunState.failed, RunState.running, RunState.waiting]) {
    group('$state historical projection', () {
      test(
        'excludes native-only output, attachments, all metadata and opaque diagnostics',
        () {
          final original = _richActivity(state: state);
          final history = _project(original);
          expect(identical(history.activity, original), isFalse);
          expect(
            identical(history.activity.models.first, original.models.first),
            isFalse,
          );
          expect(
            identical(history.activity.tools.first, original.tools.first),
            isFalse,
          );
          _expectFrozen(history.toJson());
          _expectFrozen(history.activity.tools.first.canonicalArguments);
          expect(history.activity.models.clear, throwsUnsupportedError);
          for (final value in [
            history,
            HistoricalRunEvidence.fromJson(_copy(history.toJson())),
          ]) {
            for (final model in value.activity.models) {
              expect(model.metadata, isNull);
              expect(model.failure?.providerDetails, anyOf(isNull, isEmpty));
              for (final output in model.outputs) {
                expect(output.item, isNot(isA<ModelNativeOutput>()));
                switch (output.item) {
                  case ModelTextOutput(:final providerNativeMetadata):
                    expect(providerNativeMetadata, isNull);
                  case ModelToolProposalOutput(:final providerNativeMetadata):
                    expect(providerNativeMetadata, isNull);
                  case ModelNativeOutput():
                    fail(
                      'Historical evidence reconstructed native replay output.',
                    );
                }
              }
            }
            expect(
              value.activity.failure?.providerDetails,
              anyOf(isNull, isEmpty),
            );
            for (final tool in value.activity.tools) {
              expect(tool.outcome?.hostData, anyOf(isNull, isEmpty));
              for (final change in tool.changes) {
                expect(change.outcome?.hostData, anyOf(isNull, isEmpty));
              }
            }
            final encoded = jsonEncode(value.toJson());
            for (final excluded in [
              'private-native',
              'private-presentation',
              'private-host',
              'private-provider',
              'private-model',
              'private-response',
              'private-request',
              'private-stop',
              'providerNativeMetadata',
              'providerNativeState',
              'metadata',
              'usage',
              'inputTokens',
              'outputTokens',
              'cacheReadTokens',
              'cacheWriteTokens',
              'hostData',
              'providerDetails',
              'effectiveModel',
              'providerResponseId',
              'providerRequestId',
              'providerStopReason',
            ]) {
              expect(encoded, isNot(contains(excluded)), reason: excluded);
            }
          }
          expect(original.models.first.metadata!.usage!.inputTokens, 13);
          expect(
            original.models.first.outputs[1].item,
            isA<ModelNativeOutput>(),
          );
          expect(original.tools.first.outcome!.hostData, isNotEmpty);
          expect(original.models.last.failure!.providerDetails, isNotEmpty);
        },
      );

      test(
        'JSON input and every exposed collection are detached and deeply immutable',
        () {
          final input = _copy(_project(_richActivity(state: state)).toJson());
          final history = HistoricalRunEvidence.fromJson(input);
          final expected = _copy(history.toJson());
          (_at(input, [
                    'models',
                    0,
                    'outputs',
                    1,
                    'proposal',
                    'arguments',
                  ])['nested']
                  as List)
              .clear();
          _at(input, ['tools', 0, 'canonicalArguments'])['path'] = 'changed';
          (input['models'] as List).clear();
          expect(history.toJson(), expected);
          _expectFrozen(history.toJson());
          final activity = history.activity;
          for (final list in <List<Object?>>[
            activity.lifecycle,
            activity.models,
            activity.tools,
            activity.rejectedProposals,
            activity.models.first.outputs,
            activity.tools.first.changes,
          ]) {
            expect(list.clear, throwsUnsupportedError);
          }
          _expectFrozen(activity.tools.first.canonicalArguments);
          _expectFrozen(
            (activity.models.first.outputs[1].item as ModelToolProposalOutput)
                .proposal
                .arguments,
          );
          _expectFrozen(activity.rejectedProposals.single.proposal.arguments);
          expect(
            activity.tools.first.effects!.effects.clear,
            throwsUnsupportedError,
          );
          expect(
            activity.tools.first.effects!.targets.clear,
            throwsUnsupportedError,
          );
        },
      );

      test(
        'strict codec rejects unknown, omitted and illicit opaque fields at every layer',
        () {
          final valid = _project(_richActivity(state: state)).toJson();
          final cases = <(List<Object>, String)>[
            ([], 'extra'),
            if (state == RunState.failed) (['record'], 'extra'),
            (['lifecycle', 0], 'extra'),
            (['models', 0], 'metadata'),
            (['models', 0, 'outputs', 0], 'providerNativeMetadata'),
            (['models', 0, 'outputs', 1], 'providerNativeMetadata'),
            (['models', 0, 'outputs', 1], 'proposalHandle'),
            (['models', 0, 'outputs', 1, 'proposal'], 'extra'),
            (['tools', 0], 'executable'),
            (['tools', 0, 'effects'], 'extra'),
            (['tools', 0, 'outcome'], 'hostData'),
            (['tools', 0, 'changes', 1], 'extra'),
            (['tools', 0, 'changes', 1, 'effects'], 'extra'),
            (['tools', 0, 'changes', 2], 'approvalToken'),
            (['tools', 0, 'changes', 5, 'progress'], 'extra'),
            (['tools', 0, 'changes', 6, 'outcome'], 'hostData'),
            (['rejectedProposals', 0], 'toolInvocationId'),
            (['rejectedProposals', 0, 'proposal'], 'extra'),
            (['models', 3, 'failure'], 'providerDetails'),
            if (state == RunState.failed) (['failure'], 'providerDetails'),
          ];
          for (final (path, field) in cases) {
            final value = _copy(valid);
            _at(value, path)[field] = null;
            expect(
              () => HistoricalRunEvidence.fromJson(value),
              throwsFormatException,
              reason: '$path.$field',
            );
          }
          for (final path in <List<Object>>[
            [],
            if (state == RunState.failed) ['record'],
            ['models', 0],
            ['tools', 0, 'outcome'],
          ]) {
            final value = _copy(valid);
            final target = _at(value, path);
            target.remove(target.keys.first);
            expect(
              () => HistoricalRunEvidence.fromJson(value),
              throwsFormatException,
            );
          }
          for (final (path, key, replacement)
              in <(List<Object>, String, Object?)>[
                ([], 'state', 'unknown'),
                ([], 'sequence', '90'),
                (['models', 0, 'outputs', 0], 'kind', 'providerNative'),
                (['tools', 0, 'outcome'], 'effectCertainty', 'probably'),
                (['tools', 0, 'changes', 3], 'approved', 'true'),
              ]) {
            final value = _copy(valid);
            _at(value, path)[key] = replacement;
            expect(
              () => HistoricalRunEvidence.fromJson(value),
              throwsFormatException,
            );
          }
        },
      );

      test(
        'complete projected UTF-8 JSON accepts exactly 512 KiB, rejects one byte more',
        () async {
          final original = _richActivity(state: state);
          final value = _copy(_project(original).toJson());
          final text = _at(value, ['models', 0, 'outputs', 0]);
          // Escaped controls and multibyte characters make character-count limits wrong.
          text['content'] = '\u00e9\n"';
          final overhead = utf8.encode(jsonEncode(value)).length;
          text['content'] =
              '${text['content']}${'x' * (512 * 1024 - overhead)}';
          expect(utf8.encode(jsonEncode(value)), hasLength(512 * 1024));
          final history = HistoricalRunEvidence.fromJson(value);
          expect(_project(history.activity).toJson(), value);
          final dispatcher = RemoteOrchestrationHostServiceDispatcher(
            _HistoryHost(history),
          );
          addTearDown(dispatcher.close);
          final transported = await RemoteOrchestrationHostServiceClient(
            _Channel(dispatcher),
          ).readHistoricalRun('history');
          expect(transported.toLocal().toJson(), value);
          text['content'] = '${text['content']}x';
          expect(utf8.encode(jsonEncode(value)), hasLength(512 * 1024 + 1));
          expect(() => HistoricalRunEvidence.fromJson(value), _tooLarge);
          final models = history.activity.models.toList();
          final first = models.first;
          models[0] = ModelInvocationActivity(
            id: first.id,
            startSequence: first.startSequence,
            outputs: [
              ModelOutputActivity(
                sequence: 3,
                item: ModelTextOutput(
                  text['content']! as String,
                  providerItemId: 'text-id',
                ),
              ),
              ...first.outputs.skip(1),
            ],
            terminalSequence: first.terminalSequence,
            settlement: first.settlement,
          );
          expect(
            () => _project(_withModels(history.activity, models)),
            _tooLarge,
          );
        },
      );

      test(
        'bounds count expanded values, including repeated shared subtrees',
        () {
          final value = _copy(_project(_richActivity(state: state)).toJson());
          final arguments = _at(value, ['tools', 0, 'canonicalArguments']);
          arguments.clear();
          arguments['values'] = <Object?>[];
          final remaining = 50000 - _nodes(value);
          arguments['values'] = List<Object?>.filled(
            remaining,
            null,
            growable: true,
          );
          expect(_nodes(value), 50000);
          expect(utf8.encode(jsonEncode(value)).length, lessThan(512 * 1024));
          final history = HistoricalRunEvidence.fromJson(value);
          expect(history.activity.tools, hasLength(6));
          expect(_project(history.activity).toJson(), value);
          (arguments['values'] as List).add(null);
          expect(() => HistoricalRunEvidence.fromJson(value), _tooLarge);
          final shared = List<Object?>.filled(100, null);
          arguments['values'] = List<Object?>.filled(500, shared);
          expect(
            identical(
              (arguments['values'] as List).first,
              (arguments['values'] as List).last,
            ),
            isTrue,
          );
          expect(() => HistoricalRunEvidence.fromJson(value), _tooLarge);
        },
      );

      test(
        'depth 48 succeeds and depth 49 fails without truncating evidence',
        () {
          final value = _copy(_project(_richActivity(state: state)).toJson());
          final arguments = _at(value, ['tools', 0, 'canonicalArguments']);
          // Root=0, tools=1, tool=2, arguments=3, nested value=4.
          Object? nested;
          for (var depth = 4; depth < 48; depth++) {
            nested = [nested];
          }
          arguments['deep'] = nested;
          final history = HistoricalRunEvidence.fromJson(value);
          expect(_project(history.activity).toJson(), value);
          arguments['deep'] = [nested];
          expect(() => HistoricalRunEvidence.fromJson(value), _tooLarge);
        },
      );

      test('native activity projection enforces node and depth limits too', () {
        Object? deep;
        for (var index = 0; index < 48; index++) {
          deep = [deep];
        }
        for (final arguments in <Map<String, Object?>>[
          {'values': List<Object?>.filled(50000, null)},
          {'deep': deep},
        ]) {
          final activity = RunActivitySnapshot(
            runId: RunId('bounded'),
            sessionId: SessionId('session'),
            state: state,
            sequence: 4,
            models: [
              ModelInvocationActivity(
                id: ModelInvocationId('model'),
                startSequence: 1,
                terminalSequence: 3,
                settlement: ModelSettlement.completed,
                outputs: [
                  ModelOutputActivity(
                    sequence: 2,
                    item: ModelToolProposalOutput(
                      ProviderToolProposal(
                        providerCallId: 'call',
                        alias: 'tool',
                        arguments: arguments,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
          expect(() => _project(activity), _tooLarge);
        }
      });

      test(
        'excluded native payload does not consume the projected byte budget',
        () {
          final source = _richActivity(state: state);
          final native = ModelNativeEnvelope(
            kind: 'opaque',
            compatibility: {},
            data: {'large': 'x' * (512 * 1024 + 1)},
          );
          final model = source.models.first;
          final activity = _withModels(source, [
            ModelInvocationActivity(
              id: model.id,
              startSequence: model.startSequence,
              terminalSequence: model.terminalSequence,
              settlement: model.settlement,
              outputs: [
                ModelOutputActivity(
                  sequence: 3,
                  item: ModelTextOutput(
                    'Exact\r\ntext',
                    providerItemId: 'text-id',
                    providerNativeMetadata: native,
                  ),
                ),
                ModelOutputActivity(
                  sequence: 4,
                  item: ModelNativeOutput(providerNativeMetadata: native),
                ),
                ...model.outputs.skip(2),
              ],
              metadata: ModelTerminalMetadata(providerNativeState: native),
            ),
            ...source.models.skip(1),
          ]);
          expect(_project(activity).toJson(), _project(source).toJson());
        },
      );

      test(
        'generated historical client/dispatcher roundtrip contains only the Run selector',
        () async {
          final history = _project(_richActivity(state: state));
          final host = _HistoryHost(history);
          final dispatcher = RemoteOrchestrationHostServiceDispatcher(host);
          addTearDown(dispatcher.close);
          final channel = _Channel(dispatcher);
          final remote = await RemoteOrchestrationHostServiceClient(
            channel,
          ).readHistoricalRun('history');
          expect(
            channel.method,
            'orchestrationExecutionHost.readHistoricalRun',
          );
          expect(channel.payload, {'runId': 'history'});
          expect(host.reads, ['history']);
          expect(remote.toLocal().toJson(), history.toJson());
          expect(remote.toLocal().status, history.status);
          expect(remote.toLocal().record?.state, history.record?.state);
          expect(remote.toLocal().activity.state, state);
          _expectFrozen(remote.payload);
          expect(remote.toLocal().activity.models.first.metadata, isNull);
          expect(
            remote.toLocal().activity.models.first.outputs.map(
              (output) => output.sequence,
            ),
            [3, 5, 6, 7, 8, 9, 10, 11],
          );
          for (final payload in <Map<String, Object?>>[
            {},
            {'runId': 1},
            {'runId': 'history', 'sessionId': 'foreign'},
            {'runId': 'history', 'projectId': 'foreign'},
          ]) {
            final response = await dispatcher.dispatch({
              'kind': 'request',
              'requestId': 2,
              'method': remoteOrchestrationHostServiceReadHistoricalRunId,
              'payload': payload,
            });
            expect((response['error'] as Map)['code'], 'invalid_request');
          }
          expect(host.reads, ['history']);
        },
      );

      for (final code in ['unavailable', 'current_run', 'result_too_large']) {
        test(
          'generated client reconstructs declared $code history failure',
          () async {
            final failure = RemoteHistoricalRunEvidenceFailure(
              code: code,
              message: 'Safe read failure',
              details: {'retryable': false},
            );
            final host = _HistoryHost(_project(_richActivity(state: state)))
              ..failure = failure;
            final dispatcher = RemoteOrchestrationHostServiceDispatcher(host);
            addTearDown(dispatcher.close);
            final channel = _Channel(dispatcher);
            await expectLater(
              RemoteOrchestrationHostServiceClient(
                channel,
              ).readHistoricalRun('history'),
              throwsA(
                isA<RemoteHistoricalRunEvidenceFailure>()
                    .having((error) => error.code, 'code', code)
                    .having(
                      (error) => error.message,
                      'message',
                      'Safe read failure',
                    )
                    .having((error) => error.details, 'details', {
                      'retryable': false,
                    }),
              ),
            );
            expect(
              channel.error!['declaredFailureType'],
              'orchestration.historicalRunEvidenceFailure',
            );
          },
        );
      }

      test(
        'generated decoder rejects native/unknown history payload fields',
        () async {
          final valid = _project(_richActivity(state: state)).toJson();
          for (final value in [
            {'payload': valid, 'extra': true},
            {
              'payload': {...valid, 'providerNativeState': null},
            },
            {
              'payload': {...valid}..remove('failure'),
            },
            {
              'payload': {...valid}..remove('status'),
            },
            {
              'payload': {...valid}..remove('record'),
            },
            {
              'payload': {...valid, 'status': 'unknown'},
            },
            {
              'payload': {
                ...valid,
                'status': state == RunState.failed ? 'interrupted' : 'terminal',
              },
            },
          ]) {
            await expectLater(
              RemoteOrchestrationHostServiceClient(
                _ResponseChannel(value),
              ).readHistoricalRun('history'),
              throwsA(isA<AdeleProtocolException>()),
            );
          }
        },
      );
    });
  }
}

final _tooLarge = throwsA(
  isA<HistoricalRunEvidenceFailure>().having(
    (error) => error.code,
    'code',
    'result_too_large',
  ),
);

HistoricalRunEvidence _project(RunActivitySnapshot activity) =>
    HistoricalRunEvidence.fromActivity(
      status: switch (activity.state) {
        RunState.created ||
        RunState.running ||
        RunState.waiting => HistoricalRunStatus.interrupted,
        _ => HistoricalRunStatus.terminal,
      },
      record: switch (activity.state) {
        RunState.created || RunState.running || RunState.waiting => null,
        _ => RunRecord(
          id: activity.runId,
          sessionId: activity.sessionId,
          state: RunTerminalState.values.byName(activity.state.name),
        ),
      },
      activity: activity,
    );

RunActivitySnapshot _interruptedActivity(RunState state) {
  final source = _richActivity(state: state);
  final tool = source.tools.first;
  final changes = tool.changes.take(state == RunState.waiting ? 3 : 6).toList();
  return RunActivitySnapshot(
    runId: source.runId,
    sessionId: source.sessionId,
    state: state,
    sequence: changes.last.sequence,
    lifecycle: [
      const RunLifecycleActivity(sequence: 1, state: RunState.running),
      const RunLifecycleActivity(sequence: 22, state: RunState.waiting),
      if (state == RunState.running)
        const RunLifecycleActivity(sequence: 23, state: RunState.running),
    ],
    models: [source.models.first],
    tools: [
      ToolInvocationActivity(
        id: tool.id,
        preparedSequence: tool.preparedSequence,
        modelInvocationId: tool.modelInvocationId,
        proposalSequence: tool.proposalSequence,
        toolId: tool.toolId,
        alias: tool.alias,
        providerCallId: tool.providerCallId,
        canonicalArguments: tool.canonicalArguments,
        effects: tool.effects,
        changes: changes,
      ),
    ],
  );
}

RunActivitySnapshot _withModels(
  RunActivitySnapshot source,
  List<ModelInvocationActivity> models,
) => RunActivitySnapshot(
  runId: source.runId,
  sessionId: source.sessionId,
  state: source.state,
  sequence: source.sequence,
  lifecycle: source.lifecycle,
  models: models,
  tools: source.tools,
  rejectedProposals: source.rejectedProposals,
  failure: source.failure,
);

Map<String, Object?> _copy(Map<String, Object?> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, Object?>;

Map<String, Object?> _at(Map<String, Object?> value, List<Object> path) {
  Object? current = value;
  for (final component in path) {
    current = component is int
        ? (current as List)[component]
        : (current as Map)[component];
  }
  return current! as Map<String, Object?>;
}

int _nodes(Object? value) =>
    1 +
    switch (value) {
      Map<String, Object?>() => value.values.fold(
        0,
        (sum, item) => sum + _nodes(item),
      ),
      List<Object?>() => value.fold(0, (sum, item) => sum + _nodes(item)),
      _ => 0,
    };

void _expectFrozen(Object? value) {
  if (value is Map<String, Object?>) {
    expect(() => value['mutation'] = true, throwsUnsupportedError);
    for (final item in value.values) {
      _expectFrozen(item);
    }
  } else if (value is List<Object?>) {
    expect(() => value.add(null), throwsUnsupportedError);
    for (final item in value) {
      _expectFrozen(item);
    }
  }
}

void _expectOutcome(
  ToolOutcomeActivity? actual,
  ToolOutcomeActivity? expected,
) {
  if (expected == null) {
    expect(actual, isNull);
  } else {
    expect(actual!.disposition, expected.disposition);
    expect(actual.failureKind, expected.failureKind);
    expect(actual.effectCertainty, expected.effectCertainty);
    expect(actual.modelContent, expected.modelContent);
    expect(actual.hostData, isEmpty);
  }
}

RunActivitySnapshot _richActivity({RunState state = RunState.failed}) {
  final native = ModelNativeEnvelope(
    kind: 'private-native',
    compatibility: {'private-native': true},
    data: {'private-native': 'encrypted'},
  );
  final effects = EffectDescription(
    effects: [ToolEffect.sourceMutation],
    targets: [EffectTarget(uri: Uri.parse('file:///target'))],
    summary: 'Change target',
    uncertainty: EffectUncertainty.uncertain,
  );
  final proposals = [
    for (var index = 0; index < 7; index++)
      ProviderToolProposal(
        providerCallId: 'call-$index',
        alias: index == 6 ? 'missing' : 'tool',
        arguments: {
          'path': './original',
          'nested': [index, true, null, 1.5],
        },
      ),
  ];
  final dispositions = <ToolOutcomeDisposition?>[
    ToolOutcomeDisposition.success,
    ToolOutcomeDisposition.policyDenied,
    ToolOutcomeDisposition.userRejected,
    ToolOutcomeDisposition.failure,
    ToolOutcomeDisposition.indeterminate,
    null,
  ];
  final tools = <ToolInvocationActivity>[];
  for (var index = 0; index < dispositions.length; index++) {
    final disposition = dispositions[index];
    final outcome = disposition == null
        ? null
        : ToolOutcomeActivity(
            disposition: disposition,
            failureKind: disposition == ToolOutcomeDisposition.failure
                ? ToolFailureKind.infrastructure
                : null,
            effectCertainty: index == 4
                ? EffectCertainty.uncertain
                : index == 1 || index == 2
                ? EffectCertainty.knownNotOccurred
                : EffectCertainty.knownOccurred,
            modelContent: 'Outcome $index',
            hostData: {'private-host': index},
          );
    final prepared = 20 + index * 10;
    var sequence = prepared;
    tools.add(
      ToolInvocationActivity(
        id: ToolInvocationId('tool-$index'),
        preparedSequence: prepared,
        modelInvocationId: ModelInvocationId('model'),
        proposalSequence: 5 + index,
        toolId: ToolId('test.tool'),
        alias: 'tool',
        providerCallId: 'call-$index',
        canonicalArguments: {
          'path': 'normalized',
          'nested': [index, true, null, 1.5],
        },
        effects: effects,
        outcome: outcome,
        changes: [
          ToolActivityChange(
            sequence: sequence++,
            kind: ToolActivityKind.prepared,
          ),
          ToolActivityChange(
            sequence: sequence++,
            kind: ToolActivityKind.policyEvaluated,
            policyDecision: index == 1
                ? ToolActivityPolicyDecision.deny
                : index == 0 || index == 2
                ? ToolActivityPolicyDecision.ask
                : ToolActivityPolicyDecision.allow,
            effects: effects,
          ),
          if (index == 0 || index == 2) ...[
            ToolActivityChange(
              sequence: sequence++,
              kind: ToolActivityKind.approvalRequested,
              interruptionId: RunInterruptionId('approval-$index'),
            ),
            ToolActivityChange(
              sequence: sequence++,
              kind: ToolActivityKind.approvalResolved,
              interruptionId: RunInterruptionId('approval-$index'),
              approved: index == 0,
            ),
          ],
          if (index != 1 && index != 2)
            ToolActivityChange(
              sequence: sequence++,
              kind: ToolActivityKind.executionStarted,
            ),
          if (index == 0)
            ToolActivityChange(
              sequence: sequence++,
              kind: ToolActivityKind.progress,
              progress: ToolProgress(
                kind: ToolProgressKind.stdout,
                content: 'Public progress',
              ),
            ),
          if (outcome != null)
            ToolActivityChange(
              sequence: sequence++,
              kind: ToolActivityKind.completed,
              outcome: outcome,
            ),
        ],
      ),
    );
  }
  return RunActivitySnapshot(
    runId: RunId('history'),
    sessionId: SessionId('session'),
    state: state,
    sequence: 90,
    lifecycle: [
      const RunLifecycleActivity(sequence: 1, state: RunState.running),
      const RunLifecycleActivity(sequence: 22, state: RunState.waiting),
      const RunLifecycleActivity(sequence: 23, state: RunState.running),
      const RunLifecycleActivity(sequence: 42, state: RunState.waiting),
      const RunLifecycleActivity(sequence: 43, state: RunState.running),
      RunLifecycleActivity(sequence: 90, state: state),
    ],
    models: [
      ModelInvocationActivity(
        id: ModelInvocationId('model'),
        startSequence: 2,
        terminalSequence: 12,
        settlement: ModelSettlement.completed,
        outputs: [
          ModelOutputActivity(
            sequence: 3,
            item: ModelTextOutput(
              'Exact\r\ntext',
              providerItemId: 'text-id',
              providerNativeMetadata: native,
            ),
          ),
          ModelOutputActivity(
            sequence: 4,
            item: ModelNativeOutput(
              providerItemId: 'native-id',
              providerNativeMetadata: native,
              presentation: ModelNativePresentation(
                kind: 'private-presentation',
                compactText: 'private-presentation',
                data: {'private-presentation': true},
              ),
            ),
          ),
          for (var index = 0; index < proposals.length; index++)
            ModelOutputActivity(
              sequence: 5 + index,
              item: ModelToolProposalOutput(
                proposals[index],
                providerItemId: 'proposal-$index',
                providerNativeMetadata: native,
              ),
            ),
        ],
        metadata: ModelTerminalMetadata(
          effectiveModel: 'private-model',
          providerResponseId: 'private-response',
          providerRequestId: 'private-request',
          providerStopReason: 'private-stop',
          providerNativeState: native,
          usage: ModelUsage(
            inputTokens: 13,
            outputTokens: 21,
            cacheReadTokens: 5,
            cacheWriteTokens: 8,
            providerDetails: {'private-provider': true},
          ),
        ),
      ),
      ModelInvocationActivity(
        id: ModelInvocationId('incomplete'),
        startSequence: 81,
        terminalSequence: 83,
        settlement: ModelSettlement.incomplete,
        incompleteReason: ModelIncompleteReason.outputLimit,
        outputs: [
          ModelOutputActivity(sequence: 82, item: ModelTextOutput('Partial')),
        ],
      ),
      ModelInvocationActivity(
        id: ModelInvocationId('unsettled'),
        startSequence: 84,
        outputs: [
          ModelOutputActivity(sequence: 85, item: ModelTextOutput('Unsettled')),
        ],
      ),
      ModelInvocationActivity(
        id: ModelInvocationId('failed'),
        startSequence: 86,
        terminalSequence: 88,
        outputs: [
          ModelOutputActivity(
            sequence: 87,
            item: ModelTextOutput('Before failure'),
          ),
        ],
        failure: ActivityFailure(
          kind: 'provider',
          message: 'Model failed',
          providerCode: 'provider-code',
          providerDetails: {'private-provider': true},
        ),
      ),
    ],
    tools: tools,
    rejectedProposals: [
      RejectedToolProposalActivity(
        sequence: 78,
        modelInvocationId: ModelInvocationId('model'),
        proposalSequence: 11,
        proposal: proposals.last,
        kind: ToolProposalFailureKind.unknownAlias,
        message: 'Unknown tool',
      ),
    ],
    failure: state == RunState.failed
        ? ActivityFailure(
            kind: 'strategy',
            message: 'Run failed',
            providerCode: 'run-code',
            providerDetails: {'private-provider': true},
          )
        : null,
  );
}

final class _HistoryHost implements RemoteOrchestrationHostService {
  _HistoryHost(this.history);
  final HistoricalRunEvidence history;
  final List<String> reads = [];
  RemoteHistoricalRunEvidenceFailure? failure;
  @override
  Future<RemoteHistoricalRunEvidence> readHistoricalRun(String runId) async {
    reads.add(runId);
    if (failure != null) throw failure!;
    return RemoteHistoricalRunEvidence.fromLocal(history);
  }

  @override
  Future<RemoteRunState> transition(
    RemoteRunTransition transition,
    RemoteOrchestrationFailure? failure,
  ) => throw UnimplementedError();
  @override
  Future<RemoteStrategyModelTurn> invokeModel(
    RemoteStrategyInferenceMaterial material,
  ) => throw UnimplementedError();
  @override
  Future<RemoteStrategyToolResult> processProposal(
    String toolSnapshotHandle,
    String proposalHandle,
  ) => throw UnimplementedError();
  @override
  Future<RemoteSemanticModelInput> applyCurrentApproval() =>
      throw UnimplementedError();
}

final class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
  String? method;
  Map<String, Object?>? payload;
  Map<Object?, Object?>? error;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    this.payload = payload;
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': 1,
      'method': method,
      'payload': payload,
    });
    if (response['ok'] != true) {
      error = response['error']! as Map;
      throw _WireFailure(error!);
    }
    return response['payload'];
  }
}

final class _ResponseChannel implements AdeleRequestChannel {
  _ResponseChannel(this.response);
  final Object? response;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      response;
}

final class _WireFailure implements AdeleRemoteFailure {
  _WireFailure(this.error);
  final Map<Object?, Object?> error;
  @override
  String? get declaredFailureType => error['declaredFailureType'] as String?;
  @override
  String get code => error['code']! as String;
  @override
  String get message => error['message']! as String;
  @override
  Map<String, Object?> get details =>
      Map<String, Object?>.from(error['details']! as Map);
}
