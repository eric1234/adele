import 'dart:convert';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_product/adele_product.dart';

import 'activity.dart';
import 'model.dart';
import 'run.dart';
import 'tool.dart';

/// Conservative unary bounds, including room for generated transport envelopes.
abstract final class HistoricalRunEvidenceLimits {
  static const maxBytes = 512 * 1024;
  static const maxNodes = 50000;
  static const maxDepth = 48;
}

/// A failed read never represents an empty or partially successful history.
final class HistoricalRunEvidenceFailure implements Exception {
  const HistoricalRunEvidenceFailure({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => 'HistoricalRunEvidenceFailure($code): $message';
}

/// Data-only semantic projection of retained terminal evidence, not continuation.
///
/// Reuses public activity values but excludes native-only outputs, all native
/// attachments/terminal metadata, provider details and outcome hostData. Original
/// Run-local sequences remain unchanged, including gaps left by excluded output.
/// Approval observations are facts, never approval tokens or executable handles.
final class HistoricalRunEvidence {
  HistoricalRunEvidence._(this.record, this.activity, this._json);

  factory HistoricalRunEvidence.fromActivity({
    required RunRecord record,
    required RunActivitySnapshot activity,
  }) {
    if (record.id != activity.runId ||
        record.sessionId != activity.sessionId ||
        record.state.name != activity.state.name) {
      throw const FormatException('Historical record and activity must agree.');
    }
    return HistoricalRunEvidence.fromJson({
      'runId': record.id.value,
      'sessionId': record.sessionId.value,
      'state': record.state.name,
      'sequence': activity.sequence,
      'lifecycle': [
        for (final item in activity.lifecycle)
          {'sequence': item.sequence, 'state': item.state.name},
      ],
      'models': [
        for (final model in activity.models)
          {
            'id': model.id.value,
            'startSequence': model.startSequence,
            'terminalSequence': model.terminalSequence,
            'settlement': model.settlement?.name,
            'incompleteReason': model.incompleteReason?.name,
            'failure': _failureMap(model.failure),
            'outputs': [
              for (final output in model.outputs)
                if (output.item is! ModelNativeOutput)
                  {
                    'sequence': output.sequence,
                    ...switch (output.item) {
                      ModelTextOutput(:final content, :final providerItemId) =>
                        {
                          'kind': 'text',
                          'providerItemId': providerItemId,
                          'content': content,
                        },
                      ModelToolProposalOutput(
                        :final proposal,
                        :final providerItemId,
                      ) =>
                        {
                          'kind': 'toolProposal',
                          'providerItemId': providerItemId,
                          'proposal': _proposalMap(proposal),
                        },
                      ModelNativeOutput() => throw StateError(
                        'Excluded output',
                      ),
                    },
                  },
            ],
          },
      ],
      'tools': [
        for (final tool in activity.tools)
          {
            'id': tool.id.value,
            'preparedSequence': tool.preparedSequence,
            'modelInvocationId': tool.modelInvocationId.value,
            'proposalSequence': tool.proposalSequence,
            'toolId': tool.toolId.value,
            'alias': tool.alias,
            'providerCallId': tool.providerCallId,
            'canonicalArguments': tool.canonicalArguments,
            'effects': _effectsMap(tool.effects),
            'outcome': _outcomeMap(tool.outcome),
            'changes': [
              for (final change in tool.changes)
                {
                  'sequence': change.sequence,
                  'kind': change.kind.name,
                  'policyDecision': change.policyDecision?.name,
                  'effects': _effectsMap(change.effects),
                  'interruptionId': change.interruptionId?.value,
                  'approved': change.approved,
                  'progress': change.progress == null
                      ? null
                      : {
                          'kind': change.progress!.kind.name,
                          'content': change.progress!.content,
                        },
                  'outcome': _outcomeMap(change.outcome),
                },
            ],
          },
      ],
      'rejectedProposals': [
        for (final item in activity.rejectedProposals)
          {
            'sequence': item.sequence,
            'modelInvocationId': item.modelInvocationId.value,
            'proposalSequence': item.proposalSequence,
            'proposal': _proposalMap(item.proposal),
            'kind': item.kind.name,
            'message': item.message,
          },
      ],
      'failure': _failureMap(activity.failure),
    });
  }

  /// Strict transport projection, not a durable storage or execution replay codec.
  factory HistoricalRunEvidence.fromJson(Map<String, Object?> json) {
    _validateBounds(json);
    final value = adeleSnapshotJsonMap(json);
    _fields(value, {
      'runId',
      'sessionId',
      'state',
      'sequence',
      'lifecycle',
      'models',
      'tools',
      'rejectedProposals',
      'failure',
    });
    final record = RunRecord(
      id: RunId(_read(value, 'runId')),
      sessionId: SessionId(_read(value, 'sessionId')),
      state: _enum(RunTerminalState.values, value['state']),
    );
    final activity = RunActivitySnapshot(
      runId: record.id,
      sessionId: record.sessionId,
      state: RunState.values.byName(record.state.name),
      sequence: _read(value, 'sequence'),
      lifecycle: _list(value, 'lifecycle').map((item) {
        _fields(item, {'sequence', 'state'});
        return RunLifecycleActivity(
          sequence: _read(item, 'sequence'),
          state: _enum(RunState.values, item['state']),
        );
      }),
      models: _list(value, 'models').map((item) {
        _fields(item, {
          'id',
          'startSequence',
          'terminalSequence',
          'settlement',
          'incompleteReason',
          'failure',
          'outputs',
        });
        return ModelInvocationActivity(
          id: ModelInvocationId(_read(item, 'id')),
          startSequence: _read(item, 'startSequence'),
          terminalSequence: _read<int?>(item, 'terminalSequence'),
          settlement: item['settlement'] == null
              ? null
              : _enum(ModelSettlement.values, item['settlement']),
          incompleteReason: item['incompleteReason'] == null
              ? null
              : _enum(ModelIncompleteReason.values, item['incompleteReason']),
          failure: _failure(item['failure']),
          outputs: _list(item, 'outputs').map((output) {
            final kind = _read<String>(output, 'kind');
            _fields(output, {
              'sequence',
              'kind',
              'providerItemId',
              if (kind == 'text')
                'content'
              else if (kind == 'toolProposal')
                'proposal'
              else
                throw const FormatException('Unknown output kind.'),
            });
            return ModelOutputActivity(
              sequence: _read(output, 'sequence'),
              item: kind == 'text'
                  ? ModelTextOutput(
                      _read(output, 'content'),
                      providerItemId: _read<String?>(output, 'providerItemId'),
                    )
                  : ModelToolProposalOutput(
                      _proposal(_read(output, 'proposal')),
                      providerItemId: _read<String?>(output, 'providerItemId'),
                    ),
            );
          }),
        );
      }),
      tools: _list(value, 'tools').map((item) {
        _fields(item, {
          'id',
          'preparedSequence',
          'modelInvocationId',
          'proposalSequence',
          'toolId',
          'alias',
          'providerCallId',
          'canonicalArguments',
          'effects',
          'outcome',
          'changes',
        });
        return ToolInvocationActivity(
          id: ToolInvocationId(_read(item, 'id')),
          preparedSequence: _read(item, 'preparedSequence'),
          modelInvocationId: ModelInvocationId(
            _read(item, 'modelInvocationId'),
          ),
          proposalSequence: _read(item, 'proposalSequence'),
          toolId: ToolId(_read(item, 'toolId')),
          alias: _read(item, 'alias'),
          providerCallId: _read(item, 'providerCallId'),
          canonicalArguments: _read(item, 'canonicalArguments'),
          effects: _effects(item['effects']),
          outcome: _outcome(item['outcome']),
          changes: _list(item, 'changes').map((change) {
            _fields(change, {
              'sequence',
              'kind',
              'policyDecision',
              'effects',
              'interruptionId',
              'approved',
              'progress',
              'outcome',
            });
            final progress = _optionalMap(change['progress']);
            if (progress != null) _fields(progress, {'kind', 'content'});
            return ToolActivityChange(
              sequence: _read(change, 'sequence'),
              kind: _enum(ToolActivityKind.values, change['kind']),
              policyDecision: change['policyDecision'] == null
                  ? null
                  : _enum(
                      ToolActivityPolicyDecision.values,
                      change['policyDecision'],
                    ),
              effects: _effects(change['effects']),
              interruptionId: change['interruptionId'] == null
                  ? null
                  : RunInterruptionId(_read(change, 'interruptionId')),
              approved: _read<bool?>(change, 'approved'),
              progress: progress == null
                  ? null
                  : ToolProgress(
                      kind: _enum(ToolProgressKind.values, progress['kind']),
                      content: _read(progress, 'content'),
                    ),
              outcome: _outcome(change['outcome']),
            );
          }),
        );
      }),
      rejectedProposals: _list(value, 'rejectedProposals').map((item) {
        _fields(item, {
          'sequence',
          'modelInvocationId',
          'proposalSequence',
          'proposal',
          'kind',
          'message',
        });
        return RejectedToolProposalActivity(
          sequence: _read(item, 'sequence'),
          modelInvocationId: ModelInvocationId(
            _read(item, 'modelInvocationId'),
          ),
          proposalSequence: _read(item, 'proposalSequence'),
          proposal: _proposal(_read(item, 'proposal')),
          kind: _enum(ToolProposalFailureKind.values, item['kind']),
          message: _read(item, 'message'),
        );
      }),
      failure: _failure(value['failure']),
    );
    return HistoricalRunEvidence._(record, activity, value);
  }

  final RunRecord record;
  final RunActivitySnapshot activity;
  final Map<String, Object?> _json;

  Map<String, Object?> toJson() => _json;
}

Map<String, Object?>? _failureMap(ActivityFailure? failure) => failure == null
    ? null
    : {
        'kind': failure.kind,
        'message': failure.message,
        'providerCode': failure.providerCode,
      };

ActivityFailure? _failure(Object? value) {
  final map = _optionalMap(value);
  if (map == null) return null;
  _fields(map, {'kind', 'message', 'providerCode'});
  return ActivityFailure(
    kind: _read(map, 'kind'),
    message: _read(map, 'message'),
    providerCode: _read<String?>(map, 'providerCode'),
  );
}

Map<String, Object?> _proposalMap(ProviderToolProposal proposal) => {
  'providerCallId': proposal.providerCallId,
  'alias': proposal.alias,
  'arguments': proposal.arguments,
};

ProviderToolProposal _proposal(Map<String, Object?> map) {
  _fields(map, {'providerCallId', 'alias', 'arguments'});
  return ProviderToolProposal(
    providerCallId: _read(map, 'providerCallId'),
    alias: _read(map, 'alias'),
    arguments: _read(map, 'arguments'),
  );
}

Map<String, Object?>? _outcomeMap(ToolOutcomeActivity? outcome) =>
    outcome == null
    ? null
    : {
        'disposition': outcome.disposition.name,
        'failureKind': outcome.failureKind?.name,
        'effectCertainty': outcome.effectCertainty.name,
        'modelContent': outcome.modelContent,
      };

ToolOutcomeActivity? _outcome(Object? value) {
  final map = _optionalMap(value);
  if (map == null) return null;
  _fields(map, {
    'disposition',
    'failureKind',
    'effectCertainty',
    'modelContent',
  });
  return ToolOutcomeActivity(
    disposition: _enum(ToolOutcomeDisposition.values, map['disposition']),
    failureKind: map['failureKind'] == null
        ? null
        : _enum(ToolFailureKind.values, map['failureKind']),
    effectCertainty: _enum(EffectCertainty.values, map['effectCertainty']),
    modelContent: _read(map, 'modelContent'),
  );
}

Map<String, Object?>? _effectsMap(EffectDescription? effects) => effects == null
    ? null
    : {
        'effects': [for (final effect in effects.effects) effect.name],
        'targets': [
          for (final target in effects.targets) target.uri.toString(),
        ],
        'summary': effects.summary,
        'uncertainty': effects.uncertainty.name,
      };

EffectDescription? _effects(Object? value) {
  final map = _optionalMap(value);
  if (map == null) return null;
  _fields(map, {'effects', 'targets', 'summary', 'uncertainty'});
  return EffectDescription(
    effects: _read<List<Object?>>(
      map,
      'effects',
    ).map((item) => _enum(ToolEffect.values, item)),
    targets: _read<List<Object?>>(
      map,
      'targets',
    ).map((item) => EffectTarget(uri: Uri.parse(_typed<String>(item)))),
    summary: _read(map, 'summary'),
    uncertainty: _enum(EffectUncertainty.values, map['uncertainty']),
  );
}

Map<String, Object?>? _optionalMap(Object? value) =>
    value == null ? null : _typed<Map<String, Object?>>(value);

Iterable<Map<String, Object?>> _list(Map<String, Object?> map, String key) =>
    _read<List<Object?>>(map, key).map(_typed<Map<String, Object?>>);

T _read<T>(Map<String, Object?> map, String key) => _typed<T>(map[key]);

T _typed<T>(Object? value) {
  if (value is! T) {
    throw const FormatException('Invalid historical field type.');
  }
  return value;
}

T _enum<T extends Enum>(List<T> values, Object? name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw const FormatException('Invalid historical enum value.');
}

void _fields(Map<String, Object?> map, Set<String> keys) {
  if (map.length != keys.length || !keys.every(map.containsKey)) {
    throw const FormatException('Unexpected or missing historical fields.');
  }
}

void _validateBounds(Map<String, Object?> value) {
  const tooLarge = HistoricalRunEvidenceFailure(
    code: 'result_too_large',
    message: 'Historical evidence exceeds the bounded read limit.',
  );
  var remaining = HistoricalRunEvidenceLimits.maxNodes;
  void visit(Object? item, int depth) {
    if (--remaining < 0 || depth > HistoricalRunEvidenceLimits.maxDepth) {
      throw tooLarge;
    }
    if (item is Map<String, Object?>) {
      for (final value in item.values) {
        visit(value, depth + 1);
      }
    } else if (item is List<Object?>) {
      for (final value in item) {
        visit(value, depth + 1);
      }
    }
  }

  visit(value, 0);
  if (utf8.encode(jsonEncode(value)).length >
      HistoricalRunEvidenceLimits.maxBytes) {
    throw tooLarge;
  }
}
