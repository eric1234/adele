import 'dart:convert';

import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_product/adele_product.dart';
import 'package:sqlite3/sqlite3.dart';

/// Validates data-only terminal evidence for both durable and volatile retention.
/// Sequence identities are Run-local and may have gaps, but never collide.
void validateTerminalRunActivity(
  RunRecord record,
  RunActivitySnapshot activity,
) {
  void require(bool valid, String message) {
    if (!valid) {
      throw FormatException('Invalid terminal Run activity: $message');
    }
  }

  require(
    record.id == activity.runId &&
        record.sessionId == activity.sessionId &&
        record.state.name == activity.state.name,
    'record identity, Session, or terminal state mismatch.',
  );
  require(activity.sequence >= 0, 'negative latest sequence.');
  final sequences = <int>{};
  void sequence(int value) {
    require(
      value >= 0 && value <= activity.sequence && sequences.add(value),
      'out-of-range or duplicate sequence $value.',
    );
  }

  void ordered(Iterable<int> values) {
    var previous = -1;
    for (final value in values) {
      require(value > previous, 'unordered sequences.');
      previous = value;
    }
  }

  require(activity.lifecycle.isNotEmpty, 'missing lifecycle.');
  ordered(activity.lifecycle.map((value) => value.sequence));
  for (final value in activity.lifecycle) {
    sequence(value.sequence);
    require(
      value == activity.lifecycle.last ||
          !const {
            RunState.completed,
            RunState.failed,
            RunState.cancelled,
          }.contains(value.state),
      'lifecycle continued after terminal state.',
    );
  }
  require(
    activity.lifecycle.last.state == activity.state &&
        activity.lifecycle.last.sequence == activity.sequence,
    'final lifecycle must match terminal state and latest sequence.',
  );
  require(
    (activity.failure != null) == (activity.state == RunState.failed),
    'exactly failed Runs require failure evidence.',
  );
  if (activity.failure case final failure?) _validateFailure(failure);

  final models = <ModelInvocationId, ModelInvocationActivity>{};
  final proposals = <(ModelInvocationId, int), ProviderToolProposal>{};
  ordered(activity.models.map((value) => value.startSequence));
  for (final model in activity.models) {
    require(!models.containsKey(model.id), 'duplicate model invocation.');
    models[model.id] = model;
    sequence(model.startSequence);
    ordered(model.outputs.map((value) => value.sequence));
    for (final output in model.outputs) {
      sequence(output.sequence);
      require(
        output.sequence > model.startSequence,
        'output before model start.',
      );
      if (output.item case ModelToolProposalOutput(:final proposal)) {
        proposals[(model.id, output.sequence)] = proposal;
      }
    }
    if (model.terminalSequence case final terminal?) {
      sequence(terminal);
      require(
        terminal > model.startSequence &&
            model.outputs.every((output) => output.sequence < terminal),
        'model terminal precedes its evidence.',
      );
      require(
        (model.settlement == null) != (model.failure == null),
        'model terminal requires exactly one settlement or failure.',
      );
    } else {
      require(
        model.settlement == null &&
            model.failure == null &&
            model.metadata == null,
        'unterminated model has terminal payloads.',
      );
    }
    require(
      model.settlement == null || model.metadata != null,
      'settled model requires terminal metadata.',
    );
    require(
      (model.incompleteReason != null) ==
          (model.settlement == ModelSettlement.incomplete),
      'incomplete reason without incomplete settlement.',
    );
    if (model.failure case final failure?) _validateFailure(failure);
  }

  final consumed = <(ModelInvocationId, int)>{};
  ProviderToolProposal origin(ModelInvocationId modelId, int proposal, int at) {
    final model = models[modelId];
    final value = proposals[(modelId, proposal)];
    require(
      value != null &&
          proposal >= 0 &&
          proposal < at &&
          model?.settlement == ModelSettlement.completed &&
          model!.terminalSequence! < at &&
          consumed.add((modelId, proposal)),
      'missing, reused, or invalid proposal origin.',
    );
    return value!;
  }

  final tools = <ToolInvocationId>{};
  final interruptions = <RunInterruptionId>{};
  ordered(activity.tools.map((value) => value.preparedSequence));
  for (final tool in activity.tools) {
    require(tools.add(tool.id), 'duplicate tool invocation.');
    final proposal = origin(
      tool.modelInvocationId,
      tool.proposalSequence,
      tool.preparedSequence,
    );
    require(
      tool.alias == proposal.alias &&
          tool.providerCallId == proposal.providerCallId,
      'tool proposal identity mismatch.',
    );
    require(
      tool.changes.isNotEmpty &&
          tool.changes.first.kind == ToolActivityKind.prepared &&
          tool.changes.first.sequence == tool.preparedSequence,
      'tool must begin with its prepared occurrence.',
    );
    ordered(tool.changes.map((value) => value.sequence));
    EffectDescription? effects;
    ToolOutcomeActivity? outcome;
    RunInterruptionId? pending;
    for (final change in tool.changes) {
      sequence(change.sequence);
      final allowed = switch (change.kind) {
        ToolActivityKind.prepared ||
        ToolActivityKind.executionStarted => <String>{},
        ToolActivityKind.policyEvaluated => {'policy', 'effects'},
        ToolActivityKind.policyFailed => {'effects'},
        ToolActivityKind.approvalRequested => {'interruption', 'effects'},
        ToolActivityKind.approvalResolved => {'interruption', 'approved'},
        ToolActivityKind.progress => {'progress'},
        ToolActivityKind.completed => {'outcome'},
      };
      final present = <String>{
        if (change.policyDecision != null) 'policy',
        if (change.effects != null) 'effects',
        if (change.interruptionId != null) 'interruption',
        if (change.approved != null) 'approved',
        if (change.progress != null) 'progress',
        if (change.outcome != null) 'outcome',
      };
      require(
        present.difference(allowed).isEmpty &&
            allowed.difference(present).isEmpty,
        'payload does not match tool change kind.',
      );
      require(outcome == null, 'tool continued after completion.');
      require(
        change.kind != ToolActivityKind.prepared ||
            change == tool.changes.first,
        'repeated tool preparation.',
      );
      if (change.kind == ToolActivityKind.approvalRequested) {
        require(
          pending == null && interruptions.add(change.interruptionId!),
          'duplicate approval request.',
        );
        pending = change.interruptionId;
      }
      if (change.kind == ToolActivityKind.approvalResolved) {
        require(pending == change.interruptionId, 'approval origin mismatch.');
        pending = null;
      }
      effects = change.effects ?? effects;
      outcome = change.outcome ?? outcome;
      if (change.outcome case final value?) _validateOutcome(value);
    }
    require(
      _equal(_effectsData(tool.effects), _effectsData(effects)) &&
          _sameOutcome(tool.outcome, outcome),
      'tool aggregate disagrees with its changes.',
    );
  }
  ordered(activity.rejectedProposals.map((value) => value.sequence));
  for (final rejected in activity.rejectedProposals) {
    sequence(rejected.sequence);
    final proposal = origin(
      rejected.modelInvocationId,
      rejected.proposalSequence,
      rejected.sequence,
    );
    require(
      proposal.alias == rejected.proposal.alias &&
          proposal.providerCallId == rejected.proposal.providerCallId &&
          _equal(proposal.arguments, rejected.proposal.arguments),
      'rejection proposal mismatch.',
    );
    _nonblank(rejected.message);
  }
}

/// Called only inside ProjectDatabase's record-and-evidence transaction.
void insertExecutionEvidence(Database database, RunActivitySnapshot activity) {
  final run = activity.runId.value;
  database.execute(
    'INSERT INTO adele_execution_run_activity '
    '(run_id, latest_sequence, failure_kind, failure_message, '
    'failure_provider_code, failure_provider_details_json) VALUES (?, ?, ?, ?, ?, ?)',
    [
      run,
      activity.sequence,
      activity.failure?.kind,
      activity.failure?.message,
      activity.failure?.providerCode,
      _encode(activity.failure?.providerDetails),
    ],
  );
  for (final value in activity.lifecycle) {
    database.execute(
      'INSERT INTO adele_execution_run_lifecycle VALUES (?, ?, ?)',
      [run, value.sequence, value.state.name],
    );
  }
  for (final model in activity.models) {
    final metadata = model.metadata;
    final usage = metadata?.usage;
    final native = metadata?.providerNativeState;
    database.execute(
      'INSERT INTO adele_execution_model_invocations '
      '(run_id, invocation_id, start_sequence, terminal_sequence, settlement, '
      'incomplete_reason, metadata_present, effective_model, provider_response_id, '
      'provider_request_id, provider_stop_reason, usage_present, input_tokens, '
      'output_tokens, cache_read_tokens, cache_write_tokens, usage_provider_details_json, '
      'native_state_kind, native_state_compatibility_json, native_state_data_json, '
      'failure_kind, failure_message, failure_provider_code, failure_provider_details_json) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        run,
        model.id.value,
        model.startSequence,
        model.terminalSequence,
        model.settlement?.name,
        model.incompleteReason?.name,
        metadata == null ? 0 : 1,
        metadata?.effectiveModel,
        metadata?.providerResponseId,
        metadata?.providerRequestId,
        metadata?.providerStopReason,
        usage == null ? 0 : 1,
        usage?.inputTokens,
        usage?.outputTokens,
        usage?.cacheReadTokens,
        usage?.cacheWriteTokens,
        _encode(usage?.providerDetails),
        native?.kind,
        _encode(native?.compatibility),
        _encode(native?.data),
        model.failure?.kind,
        model.failure?.message,
        model.failure?.providerCode,
        _encode(model.failure?.providerDetails),
      ],
    );
    for (final output in model.outputs) {
      final item = output.item;
      final (
        kind,
        text,
        itemId,
        native,
        presentation,
        proposal,
      ) = switch (item) {
        ModelTextOutput() => (
          'text',
          item.content,
          item.providerItemId,
          item.providerNativeMetadata,
          null,
          null,
        ),
        ModelNativeOutput() => (
          'native',
          null,
          item.providerItemId,
          item.providerNativeMetadata,
          item.presentation,
          null,
        ),
        ModelToolProposalOutput() => (
          'toolProposal',
          null,
          item.providerItemId,
          item.providerNativeMetadata,
          null,
          item.proposal,
        ),
      };
      database.execute(
        'INSERT INTO adele_execution_model_outputs '
        '(run_id, model_invocation_id, sequence, kind, text_content, provider_item_id, '
        'native_metadata_kind, native_metadata_compatibility_json, native_metadata_data_json, '
        'presentation_kind, presentation_compact_text, presentation_data_json, '
        'provider_call_id, alias, arguments_json) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          run,
          model.id.value,
          output.sequence,
          kind,
          text,
          itemId,
          native?.kind,
          _encode(native?.compatibility),
          _encode(native?.data),
          presentation?.kind,
          presentation?.compactText,
          _encode(presentation?.data),
          proposal?.providerCallId,
          proposal?.alias,
          _encode(proposal?.arguments),
        ],
      );
    }
  }
  for (final tool in activity.tools) {
    database.execute(
      'INSERT INTO adele_execution_tool_invocations '
      '(run_id, invocation_id, prepared_sequence, model_invocation_id, proposal_sequence, '
      'tool_id, alias, provider_call_id, canonical_arguments_json) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        run,
        tool.id.value,
        tool.preparedSequence,
        tool.modelInvocationId.value,
        tool.proposalSequence,
        tool.toolId.value,
        tool.alias,
        tool.providerCallId,
        jsonEncode(tool.canonicalArguments),
      ],
    );
    for (final change in tool.changes) {
      database.execute(
        'INSERT INTO adele_execution_tool_changes '
        '(run_id, tool_invocation_id, sequence, kind, policy_decision, effects_json, '
        'interruption_id, approved, progress_kind, progress_content, outcome_disposition, '
        'failure_kind, effect_certainty, model_content, host_data_json) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          run,
          tool.id.value,
          change.sequence,
          change.kind.name,
          change.policyDecision?.name,
          _encode(_effectsData(change.effects)),
          change.interruptionId?.value,
          change.approved == null ? null : (change.approved! ? 1 : 0),
          change.progress?.kind.name,
          change.progress?.content,
          change.outcome?.disposition.name,
          change.outcome?.failureKind?.name,
          change.outcome?.effectCertainty.name,
          change.outcome?.modelContent,
          _encode(change.outcome?.hostData),
        ],
      );
    }
  }
  for (final value in activity.rejectedProposals) {
    database.execute(
      'INSERT INTO adele_execution_rejected_proposals VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        run,
        value.sequence,
        value.modelInvocationId.value,
        value.proposalSequence,
        value.proposal.providerCallId,
        value.proposal.alias,
        jsonEncode(value.proposal.arguments),
        value.kind.name,
        value.message,
      ],
    );
  }
}

/// Reads all execution-owned rows, including orphans, before returning any history.
List<RunActivitySnapshot> loadExecutionEvidence(
  Database database,
  Iterable<RunRecord> records,
) {
  final byId = <String, RunRecord>{};
  for (final record in records) {
    if (byId.containsKey(record.id.value)) {
      throw const FormatException('Duplicate terminal Run record.');
    }
    byId[record.id.value] = record;
  }
  final productRows = database.select('SELECT * FROM adele_product_runs');
  if (productRows.length != byId.length) {
    throw const FormatException(
      'Execution history requires all terminal records.',
    );
  }
  final seenRecords = <String>{};
  for (final row in productRows) {
    final record = byId[_text(row, 'id')];
    if (record == null ||
        !seenRecords.add(record.id.value) ||
        record.sessionId.value != _text(row, 'session_id') ||
        record.state.name != _text(row, 'terminal_state')) {
      throw const FormatException('Terminal product record mismatch.');
    }
  }
  final roots = <String, Row>{};
  for (final row in database.select(
    'SELECT * FROM adele_execution_run_activity',
  )) {
    final id = _text(row, 'run_id');
    if (!byId.containsKey(id) || roots.containsKey(id)) {
      throw const FormatException('Orphan or duplicate Run activity root.');
    }
    roots[id] = row;
  }
  if (roots.length != byId.length) {
    throw const FormatException('Missing terminal Run activity root.');
  }
  Map<String, List<Row>> rows(String table, String order) {
    final result = <String, List<Row>>{};
    for (final row in database.select(
      'SELECT * FROM adele_execution_$table ORDER BY $order',
    )) {
      final run = _text(row, 'run_id');
      if (!roots.containsKey(run)) {
        throw FormatException('Orphan execution $table row.');
      }
      (result[run] ??= []).add(row);
    }
    return result;
  }

  final lifecycle = rows('run_lifecycle', 'sequence');
  final models = rows('model_invocations', 'start_sequence');
  final outputs = rows('model_outputs', 'sequence');
  final tools = rows('tool_invocations', 'prepared_sequence');
  final changes = rows('tool_changes', 'sequence');
  final rejections = rows('rejected_proposals', 'sequence');
  final result = <RunActivitySnapshot>[];
  for (final entry in roots.entries) {
    final run = entry.key;
    final record = byId[run]!;
    final modelRows = models[run] ?? [];
    final toolRows = tools[run] ?? [];
    final modelIds = modelRows
        .map((row) => _text(row, 'invocation_id'))
        .toSet();
    final toolIds = toolRows.map((row) => _text(row, 'invocation_id')).toSet();
    final modelOutputs = <String, List<ModelOutputActivity>>{};
    for (final row in outputs[run] ?? <Row>[]) {
      final id = _text(row, 'model_invocation_id');
      if (!modelIds.contains(id)) {
        throw const FormatException('Orphan model output.');
      }
      (modelOutputs[id] ??= []).add(
        ModelOutputActivity(
          sequence: _integer(row, 'sequence'),
          item: _outputFrom(row),
        ),
      );
    }
    final toolChanges = <String, List<ToolActivityChange>>{};
    for (final row in changes[run] ?? <Row>[]) {
      final id = _text(row, 'tool_invocation_id');
      if (!toolIds.contains(id)) {
        throw const FormatException('Orphan tool change.');
      }
      (toolChanges[id] ??= []).add(_changeFrom(row));
    }
    final activity = RunActivitySnapshot(
      runId: record.id,
      sessionId: record.sessionId,
      state: RunState.values.byName(record.state.name),
      sequence: _integer(entry.value, 'latest_sequence'),
      failure: _failureFrom(entry.value),
      lifecycle: [
        for (final row in lifecycle[run] ?? <Row>[])
          RunLifecycleActivity(
            sequence: _integer(row, 'sequence'),
            state: RunState.values.byName(_text(row, 'state')),
          ),
      ],
      models: [
        for (final row in modelRows)
          ModelInvocationActivity(
            id: ModelInvocationId(_text(row, 'invocation_id')),
            startSequence: _integer(row, 'start_sequence'),
            terminalSequence: _optionalInteger(row, 'terminal_sequence'),
            settlement: _optionalEnum(
              row,
              'settlement',
              ModelSettlement.values,
            ),
            incompleteReason: _optionalEnum(
              row,
              'incomplete_reason',
              ModelIncompleteReason.values,
            ),
            metadata: _metadataFrom(row),
            failure: _failureFrom(row),
            outputs: modelOutputs[_text(row, 'invocation_id')] ?? [],
          ),
      ],
      tools: [
        for (final row in toolRows)
          _toolFrom(row, toolChanges[_text(row, 'invocation_id')] ?? []),
      ],
      rejectedProposals: [
        for (final row in rejections[run] ?? <Row>[])
          RejectedToolProposalActivity(
            sequence: _integer(row, 'sequence'),
            modelInvocationId: ModelInvocationId(
              _text(row, 'model_invocation_id'),
            ),
            proposalSequence: _integer(row, 'proposal_sequence'),
            proposal: _proposalFrom(row),
            kind: ToolProposalFailureKind.values.byName(
              _text(row, 'failure_kind'),
            ),
            message: _text(row, 'message'),
          ),
      ],
    );
    validateTerminalRunActivity(record, activity);
    result.add(activity);
  }
  return List.unmodifiable(result);
}

ModelOutputItem _outputFrom(Row row) {
  final kind = _text(row, 'kind');
  final text = _optionalText(row, 'text_content');
  final itemId = _optionalText(row, 'provider_item_id');
  final native = _nativeFrom(row, 'native_metadata');
  final presentation = _presentationFrom(row);
  final hasProposal =
      row['provider_call_id'] != null ||
      row['alias'] != null ||
      row['arguments_json'] != null;
  if ((kind != 'text' && text != null) ||
      (kind != 'native' && presentation != null) ||
      (kind != 'toolProposal' && hasProposal)) {
    throw const FormatException('Model output payload does not match kind.');
  }
  return switch (kind) {
    'text' => ModelTextOutput(
      _text(row, 'text_content'),
      providerItemId: itemId,
      providerNativeMetadata: native,
    ),
    'native' when native != null => ModelNativeOutput(
      providerNativeMetadata: native,
      providerItemId: itemId,
      presentation: presentation,
    ),
    'toolProposal' => ModelToolProposalOutput(
      _proposalFrom(row),
      providerItemId: itemId,
      providerNativeMetadata: native,
    ),
    _ => throw const FormatException(
      'Invalid model output kind or native payload.',
    ),
  };
}

ProviderToolProposal _proposalFrom(Row row) => ProviderToolProposal(
  providerCallId: _text(row, 'provider_call_id'),
  alias: _text(row, 'alias'),
  arguments: _jsonMap(row, 'arguments_json'),
);

ToolInvocationActivity _toolFrom(Row row, List<ToolActivityChange> changes) {
  EffectDescription? effects;
  ToolOutcomeActivity? outcome;
  for (final change in changes) {
    effects = change.effects ?? effects;
    outcome = change.outcome ?? outcome;
  }
  return ToolInvocationActivity(
    id: ToolInvocationId(_text(row, 'invocation_id')),
    preparedSequence: _integer(row, 'prepared_sequence'),
    modelInvocationId: ModelInvocationId(_text(row, 'model_invocation_id')),
    proposalSequence: _integer(row, 'proposal_sequence'),
    toolId: ToolId(_text(row, 'tool_id')),
    alias: _text(row, 'alias'),
    providerCallId: _text(row, 'provider_call_id'),
    canonicalArguments: _jsonMap(row, 'canonical_arguments_json'),
    effects: effects,
    outcome: outcome,
    changes: changes,
  );
}

ToolActivityChange _changeFrom(Row row) {
  final approved = _optionalInteger(row, 'approved');
  if (approved != null && approved != 0 && approved != 1) {
    throw const FormatException('Invalid approval boolean.');
  }
  final progressKind = _optionalEnum(
    row,
    'progress_kind',
    ToolProgressKind.values,
  );
  final progressContent = _optionalText(row, 'progress_content');
  if ((progressKind == null) != (progressContent == null)) {
    throw const FormatException('Incomplete progress payload.');
  }
  final interruption = _optionalText(row, 'interruption_id');
  return ToolActivityChange(
    sequence: _integer(row, 'sequence'),
    kind: ToolActivityKind.values.byName(_text(row, 'kind')),
    policyDecision: _optionalEnum(
      row,
      'policy_decision',
      ToolActivityPolicyDecision.values,
    ),
    effects: _optionalJson(row, 'effects_json', _effectsFrom),
    interruptionId: interruption == null
        ? null
        : RunInterruptionId(interruption),
    approved: approved == null ? null : approved == 1,
    progress: progressKind == null
        ? null
        : ToolProgress(kind: progressKind, content: progressContent!),
    outcome: _outcomeFrom(row),
  );
}

String _text(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! String) throw FormatException('Expected text for $key.');
  return field;
}

String? _optionalText(Map<String, Object?> value, String key) =>
    value[key] == null ? null : _text(value, key);
int _integer(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! int) throw FormatException('Expected integer for $key.');
  return field;
}

int? _optionalInteger(Map<String, Object?> value, String key) =>
    value[key] == null ? null : _integer(value, key);
T? _optionalEnum<T extends Enum>(
  Map<String, Object?> value,
  String key,
  List<T> values,
) => value[key] == null ? null : values.byName(_text(value, key));
Map<String, Object?> _map(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const FormatException('Expected JSON object.');
  }
  return value;
}

Map<String, Object?> _jsonMap(Row row, String column) =>
    _map(jsonDecode(_text(row, column)));
T? _optionalJson<T>(
  Row row,
  String column,
  T Function(Map<String, Object?>) decode,
) => row[column] == null ? null : decode(_jsonMap(row, column));
String? _encode(Object? value) => value == null ? null : jsonEncode(value);
void _shape(Map<String, Object?> value, Set<String> keys) {
  if (value.length != keys.length || !keys.every(value.containsKey)) {
    throw const FormatException('Invalid structured evidence fields.');
  }
}

String _nonblank(String value) {
  if (value.trim().isEmpty) throw const FormatException('Empty evidence text.');
  return value;
}

bool _equal(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _equal(a[key], b[key]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        Iterable<int>.generate(
          a.length,
        ).every((index) => _equal(a[index], b[index]));
  }
  return a == b;
}

void _requireNull(Row row, Iterable<String> columns) {
  for (final column in columns) {
    if (row[column] != null) {
      throw FormatException('Unexpected payload in $column.');
    }
  }
}

bool _presence(Row row, String column) {
  return switch (_integer(row, column)) {
    0 => false,
    1 => true,
    _ => throw FormatException('Invalid presence flag $column.'),
  };
}

ActivityFailure? _failureFrom(Row row) {
  final kind = _optionalText(row, 'failure_kind');
  if (kind == null) {
    _requireNull(row, [
      'failure_message',
      'failure_provider_code',
      'failure_provider_details_json',
    ]);
    return null;
  }
  final failure = ActivityFailure(
    kind: kind,
    message: _text(row, 'failure_message'),
    providerCode: _optionalText(row, 'failure_provider_code'),
    providerDetails: _jsonMap(row, 'failure_provider_details_json'),
  );
  _validateFailure(failure);
  return failure;
}

void _validateFailure(ActivityFailure value) {
  _nonblank(value.kind);
  _nonblank(value.message);
  if (value.providerCode case final code?) _nonblank(code);
}

ModelNativeEnvelope? _nativeFrom(Row row, String prefix) {
  final kind = _optionalText(row, '${prefix}_kind');
  if (kind == null) {
    _requireNull(row, ['${prefix}_compatibility_json', '${prefix}_data_json']);
    return null;
  }
  return ModelNativeEnvelope(
    kind: kind,
    compatibility: _jsonMap(row, '${prefix}_compatibility_json'),
    data: _jsonMap(row, '${prefix}_data_json'),
  );
}

ModelNativePresentation? _presentationFrom(Row row) {
  final kind = _optionalText(row, 'presentation_kind');
  if (kind == null) {
    _requireNull(row, ['presentation_compact_text', 'presentation_data_json']);
    return null;
  }
  return ModelNativePresentation(
    kind: kind,
    compactText: _text(row, 'presentation_compact_text'),
    data: _jsonMap(row, 'presentation_data_json'),
  );
}

ModelTerminalMetadata? _metadataFrom(Row row) {
  final present = _presence(row, 'metadata_present');
  final usagePresent = _presence(row, 'usage_present');
  final native = _nativeFrom(row, 'native_state');
  ModelUsage? usage;
  if (usagePresent) {
    usage = ModelUsage(
      inputTokens: _optionalInteger(row, 'input_tokens'),
      outputTokens: _optionalInteger(row, 'output_tokens'),
      cacheReadTokens: _optionalInteger(row, 'cache_read_tokens'),
      cacheWriteTokens: _optionalInteger(row, 'cache_write_tokens'),
      providerDetails: _jsonMap(row, 'usage_provider_details_json'),
    );
  } else {
    _requireNull(row, [
      'input_tokens',
      'output_tokens',
      'cache_read_tokens',
      'cache_write_tokens',
      'usage_provider_details_json',
    ]);
  }
  if (!present) {
    _requireNull(row, [
      'effective_model',
      'provider_response_id',
      'provider_request_id',
      'provider_stop_reason',
    ]);
    if (usage != null || native != null) {
      throw const FormatException('Absent metadata has usage or native state.');
    }
    return null;
  }
  return ModelTerminalMetadata(
    effectiveModel: _optionalText(row, 'effective_model'),
    providerResponseId: _optionalText(row, 'provider_response_id'),
    providerRequestId: _optionalText(row, 'provider_request_id'),
    providerStopReason: _optionalText(row, 'provider_stop_reason'),
    usage: usage,
    providerNativeState: native,
  );
}

Map<String, Object?>? _effectsData(EffectDescription? value) => value == null
    ? null
    : {
        'effects': value.effects.map((effect) => effect.name).toList()..sort(),
        'targets': value.targets
            .map((target) => target.uri.toString())
            .toList(),
        'summary': value.summary,
        'uncertainty': value.uncertainty.name,
      };
EffectDescription _effectsFrom(Map<String, Object?> value) {
  _shape(value, {'effects', 'targets', 'summary', 'uncertainty'});
  final effects = value['effects'];
  final targets = value['targets'];
  if (effects is! List ||
      targets is! List ||
      effects.any((item) => item is! String) ||
      targets.any((item) => item is! String) ||
      effects.toSet().length != effects.length) {
    throw const FormatException('Invalid effect names or target URIs.');
  }
  return EffectDescription(
    effects: effects.map((item) => ToolEffect.values.byName(item as String)),
    targets: targets.map((item) {
      final uri = Uri.parse(item as String);
      if (uri.toString() != item) {
        throw const FormatException('Noncanonical effect URI.');
      }
      return EffectTarget(uri: uri);
    }),
    summary: _text(value, 'summary'),
    uncertainty: EffectUncertainty.values.byName(_text(value, 'uncertainty')),
  );
}

bool _sameOutcome(ToolOutcomeActivity? a, ToolOutcomeActivity? b) =>
    a == null || b == null
    ? a == b
    : a.disposition == b.disposition &&
          a.failureKind == b.failureKind &&
          a.effectCertainty == b.effectCertainty &&
          a.modelContent == b.modelContent &&
          _equal(a.hostData, b.hostData);

ToolOutcomeActivity? _outcomeFrom(Row row) {
  final disposition = _optionalEnum(
    row,
    'outcome_disposition',
    ToolOutcomeDisposition.values,
  );
  if (disposition == null) {
    _requireNull(row, [
      'failure_kind',
      'effect_certainty',
      'model_content',
      'host_data_json',
    ]);
    return null;
  }
  final result = ToolOutcomeActivity(
    disposition: disposition,
    failureKind: _optionalEnum(row, 'failure_kind', ToolFailureKind.values),
    effectCertainty: EffectCertainty.values.byName(
      _text(row, 'effect_certainty'),
    ),
    modelContent: _text(row, 'model_content'),
    hostData: _jsonMap(row, 'host_data_json'),
  );
  _validateOutcome(result);
  return result;
}

void _validateOutcome(ToolOutcomeActivity value) {
  _nonblank(value.modelContent);
  if ((value.disposition == ToolOutcomeDisposition.failure) !=
      (value.failureKind != null)) {
    throw const FormatException('Invalid tool outcome failure kind.');
  }
}
