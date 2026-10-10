import 'dart:convert';

import 'package:session_evaluator_contract/session_evaluator_contract.dart';

import 'evidence_tables.dart';

void evidenceRequire(bool valid, String message) {
  if (!valid) {
    throw SessionEvidenceFailure(code: 'malformed_data', message: message);
  }
}

bool _nonblank(Object? value) => value is String && value.trim().isNotEmpty;
bool _identity(Object? value) =>
    _nonblank(value) && value == (value as String).trim();

void validateEvidenceRow(EvidenceTable table, Map<String, Object?> row) {
  evidenceRequire(
    row.length == table.columns.length &&
        row.keys.toSet().containsAll(table.columns),
    'Unexpected columns in ${table.name}.',
  );
  for (final key in table.columns) {
    final value = row[key];
    final nullable =
        table.nullableText.contains(key) ||
        table.nullableIntegers.contains(key);
    final integer =
        table.integers.contains(key) || table.nullableIntegers.contains(key);
    evidenceRequire(
      value == null
          ? nullable
          : (integer ? value is int && value >= 0 : value is String),
      'Invalid ${table.name}.$key.',
    );
    if (value != null && (key.endsWith('_id') || key == 'id')) {
      evidenceRequire(
        key.startsWith('provider_') ? _nonblank(value) : _identity(value),
        'Invalid identity ${table.name}.$key.',
      );
    }
    if (value != null &&
        const [
          'alias',
          'effective_model',
          'provider_stop_reason',
          'native_state_kind',
          'native_metadata_kind',
        ].contains(key)) {
      evidenceRequire(
        _nonblank(value),
        'Empty evidence field ${table.name}.$key.',
      );
    }
    if (value != null && key.endsWith('_json')) {
      Object? decoded;
      try {
        decoded = jsonDecode(value as String);
      } on FormatException {
        evidenceRequire(false, 'Malformed JSON in ${table.name}.$key.');
      }
      evidenceRequire(
        decoded is Map<String, dynamic>,
        'Expected JSON object in ${table.name}.$key.',
      );
      _jsonValue(decoded, 0);
    }
  }
}

void _jsonValue(Object? value, int depth) {
  evidenceRequire(depth <= 64, 'Structured evidence exceeds supported depth.');
  if (value is Map) {
    for (final child in value.values) {
      _jsonValue(child, depth + 1);
    }
  } else if (value is List) {
    for (final child in value) {
      _jsonValue(child, depth + 1);
    }
  } else if (value is double) {
    evidenceRequire(value.isFinite, 'Nonfinite structured evidence number.');
  }
}

void validateConversation(Map<String, Object?> conversation) {
  final entries = conversation['entries'] as List<Map<String, Object?>>;
  final configuration = conversation['configuration'] as Map<String, Object?>?;
  if (configuration == null) {
    evidenceRequire(entries.isEmpty, 'Conversation without configuration.');
    return;
  }
  evidenceRequire(
    (configuration['max_model_invocations'] as int) > 0 &&
        configuration['next_entry'] == entries.length,
    'Chat configuration/counter disagrees with retained entries (or changed during reads).',
  );
  final runs = <String>{};
  for (var index = 0; index < entries.length; index++) {
    final entry = entries[index];
    evidenceRequire(
      entry['sequence'] == index &&
          entry['entry_id'] == 'entry-$index' &&
          const ['user', 'assistant'].contains(entry['role']) &&
          _nonblank(entry['content']),
      'Invalid canonical Chat entry at sequence $index.',
    );
    final run = entry['run_id'];
    evidenceRequire(
      run == null || (entry['role'] == 'user' && runs.add(run as String)),
      'Invalid or duplicate Chat Run association.',
    );
  }
}

void _failure(Map<String, Object?> row) {
  final kind = row['failure_kind'];
  evidenceRequire(
    kind == null
        ? row['failure_message'] == null &&
              row['failure_provider_code'] == null &&
              row['failure_provider_details_json'] == null
        : _nonblank(kind) &&
              _nonblank(row['failure_message']) &&
              row['failure_provider_details_json'] != null &&
              (row['failure_provider_code'] == null ||
                  _nonblank(row['failure_provider_code'])),
    'Incomplete failure evidence.',
  );
}

void validateRunEvidence(Map<String, Object?> run) {
  const terminalStates = ['completed', 'failed', 'cancelled'];
  evidenceRequire(
    terminalStates.contains(run['terminal_state']),
    'Invalid terminal Run state.',
  );
  final evidence = run['evidence'] as Map<String, Object?>;
  final root = evidence['root'] as Map<String, Object?>;
  final latest = root['latest_sequence'] as int;
  final sequences = <int>{};
  void occurrence(Object? value) {
    evidenceRequire(
      value is int && value >= 0 && value <= latest && sequences.add(value),
      'Duplicate or out-of-range Run-local occurrence.',
    );
  }

  List<Map<String, Object?>> rows(String key) =>
      evidence[key] as List<Map<String, Object?>>;

  _failure(root);
  evidenceRequire(
    (root['failure_kind'] != null) == (run['terminal_state'] == 'failed'),
    'Run failure disagrees with terminal state.',
  );
  final lifecycle = rows('lifecycle');
  evidenceRequire(lifecycle.isNotEmpty, 'Missing Run lifecycle.');
  for (final entry in lifecycle) {
    occurrence(entry['sequence']);
    evidenceRequire(
      const [
        'created',
        'running',
        'waiting',
        ...terminalStates,
      ].contains(entry['state']),
      'Invalid lifecycle state.',
    );
    evidenceRequire(
      identical(entry, lifecycle.last) ||
          !terminalStates.contains(entry['state']),
      'Lifecycle continued after terminal state.',
    );
  }
  evidenceRequire(
    lifecycle.last['sequence'] == latest &&
        lifecycle.last['state'] == run['terminal_state'],
    'Terminal lifecycle disagrees with Run/root.',
  );

  final models = <String, Map<String, Object?>>{};
  for (final model in rows('model_invocations')) {
    evidenceRequire(
      !models.containsKey(model['invocation_id']),
      'Duplicate model identity.',
    );
    models[model['invocation_id'] as String] = model;
    occurrence(model['start_sequence']);
    _failure(model);
    final terminal = model['terminal_sequence'];
    final settlement = model['settlement'];
    final failure = model['failure_kind'];
    final metadata = model['metadata_present'];
    final usage = model['usage_present'];
    evidenceRequire(
      const [0, 1].contains(metadata) && const [0, 1].contains(usage),
      'Invalid model presence flag.',
    );
    if (terminal == null) {
      evidenceRequire(
        settlement == null && failure == null && metadata == 0,
        'Unterminated model has terminal payload.',
      );
    } else {
      occurrence(terminal);
      evidenceRequire(
        (terminal as int) > (model['start_sequence'] as int) &&
            ((settlement == null) != (failure == null)),
        'Invalid model terminal occurrence.',
      );
    }
    evidenceRequire(
      settlement == null ||
          (const ['completed', 'incomplete', 'refused'].contains(settlement) &&
              metadata == 1),
      'Invalid model settlement or missing metadata.',
    );
    evidenceRequire(
      settlement == 'incomplete'
          ? const [
              'outputLimit',
              'contextLimit',
              'other',
            ].contains(model['incomplete_reason'])
          : model['incomplete_reason'] == null,
      'Invalid incomplete reason.',
    );
    if (metadata == 0) {
      evidenceRequire(
        usage == 0 &&
            const [
              'effective_model',
              'provider_response_id',
              'provider_request_id',
              'provider_stop_reason',
              'native_state_kind',
            ].every((key) => model[key] == null),
        'Metadata payload without metadata.',
      );
    }
    evidenceRequire(
      usage == 1
          ? model['usage_provider_details_json'] != null
          : const [
              'input_tokens',
              'output_tokens',
              'cache_read_tokens',
              'cache_write_tokens',
              'usage_provider_details_json',
            ].every((key) => model[key] == null),
      'Usage presence disagrees with reported data.',
    );
  }

  final outputs = <int, Map<String, Object?>>{};
  for (final output in rows('model_outputs')) {
    final sequence = output['sequence'] as int;
    occurrence(sequence);
    outputs[sequence] = output;
    final model = models[output['model_invocation_id']];
    evidenceRequire(
      model != null &&
          sequence > (model['start_sequence'] as int) &&
          (model['terminal_sequence'] == null ||
              sequence < (model['terminal_sequence'] as int)),
      'Output has invalid model provenance.',
    );
    final proposal = ['provider_call_id', 'alias', 'arguments_json'];
    final presentation = [
      'presentation_kind',
      'presentation_compact_text',
      'presentation_data_json',
    ];
    switch (output['kind']) {
      case 'text':
        evidenceRequire(
          output['text_content'] is String &&
              (output['text_content'] as String).isNotEmpty &&
              [...proposal, ...presentation].every((k) => output[k] == null),
          'Invalid text output.',
        );
      case 'toolProposal':
        evidenceRequire(
          proposal.every((k) => _nonblank(output[k])) &&
              output['text_content'] == null &&
              presentation.every((k) => output[k] == null),
          'Invalid tool proposal output.',
        );
      case 'native':
        evidenceRequire(
          _nonblank(output['native_metadata_kind']) &&
              output['text_content'] == null &&
              proposal.every((k) => output[k] == null),
          'Invalid native output.',
        );
        evidenceRequire(
          output['presentation_kind'] == null
              ? presentation.every((k) => output[k] == null)
              : presentation.every((k) => _nonblank(output[k])),
          'Incomplete safe presentation.',
        );
      default:
        evidenceRequire(false, 'Unsupported model output kind.');
    }
  }

  final consumed = <int>{};
  void origin(Map<String, Object?> value, int at, {bool rejected = false}) {
    final proposal = value['proposal_sequence'] as int;
    final output = outputs[proposal];
    final model = models[value['model_invocation_id']];
    evidenceRequire(
      output != null &&
          model != null &&
          output['kind'] == 'toolProposal' &&
          output['model_invocation_id'] == value['model_invocation_id'] &&
          proposal < at &&
          model['settlement'] == 'completed' &&
          (model['terminal_sequence'] as int) < at &&
          consumed.add(proposal) &&
          output['alias'] == value['alias'] &&
          output['provider_call_id'] == value['provider_call_id'],
      'Invalid or reused proposal provenance.',
    );
    if (rejected) {
      evidenceRequire(
        _sameJson(
          jsonDecode(output!['arguments_json'] as String),
          jsonDecode(value['arguments_json'] as String),
        ),
        'Rejected proposal arguments changed.',
      );
    }
  }

  final tools = <String, Map<String, Object?>>{};
  final changes = <String, List<Map<String, Object?>>>{};
  for (final tool in rows('tool_invocations')) {
    final id = tool['invocation_id'] as String;
    evidenceRequire(!tools.containsKey(id), 'Duplicate tool identity.');
    tools[id] = tool;
    changes[id] = [];
    origin(tool, tool['prepared_sequence'] as int);
  }
  for (final change in rows('tool_changes')) {
    occurrence(change['sequence']);
    final target = changes[change['tool_invocation_id']];
    evidenceRequire(
      target != null,
      'Tool change has no invocation in this Run.',
    );
    target!.add(change);
  }
  final interruptions = <String>{};
  for (final entry in tools.entries) {
    final history = changes[entry.key]!;
    evidenceRequire(
      history.isNotEmpty &&
          history.first['kind'] == 'prepared' &&
          history.first['sequence'] == entry.value['prepared_sequence'],
      'Missing tool preparation.',
    );
    String? pending;
    var completed = false;
    for (final change in history) {
      evidenceRequire(!completed, 'Tool changed after completion.');
      evidenceRequire(
        change['kind'] != 'prepared' || identical(change, history.first),
        'Repeated preparation.',
      );
      final fields = switch (change['kind']) {
        'prepared' || 'executionStarted' => <String>{},
        'policyEvaluated' => {'policy_decision', 'effects_json'},
        'policyFailed' => {'effects_json'},
        'approvalRequested' => {'interruption_id', 'effects_json'},
        'approvalResolved' => {'interruption_id', 'approved'},
        'progress' => {'progress_kind', 'progress_content'},
        'completed' => {
          'outcome_disposition',
          'effect_certainty',
          'model_content',
          'host_data_json',
          if (change['outcome_disposition'] == 'failure') 'failure_kind',
        },
        _ => null,
      };
      evidenceRequire(fields != null, 'Unsupported tool change.');
      for (final field in [
        ...executionTables['tool_changes']!.nullableText,
        'approved',
      ]) {
        evidenceRequire(
          (change[field] != null) == fields!.contains(field),
          'Tool change payload disagrees with kind.',
        );
      }
      if (change['policy_decision'] != null) {
        evidenceRequire(
          const ['allow', 'deny', 'ask'].contains(change['policy_decision']),
          'Invalid tool policy.',
        );
      }
      if (change['effects_json'] != null) {
        _effects(
          jsonDecode(change['effects_json'] as String) as Map<String, dynamic>,
        );
      }
      if (change['kind'] == 'approvalRequested') {
        evidenceRequire(
          pending == null &&
              interruptions.add(change['interruption_id'] as String),
          'Duplicate approval request.',
        );
        pending = change['interruption_id'] as String;
      }
      if (change['kind'] == 'approvalResolved') {
        evidenceRequire(
          pending != null &&
              pending == change['interruption_id'] &&
              const [0, 1].contains(change['approved']),
          'Invalid approval resolution.',
        );
        pending = null;
      }
      if (change['kind'] == 'progress') {
        evidenceRequire(
          const [
                'status',
                'stdout',
                'stderr',
              ].contains(change['progress_kind']) &&
              (change['progress_content'] as String).isNotEmpty,
          'Invalid tool progress.',
        );
      }
      if (change['kind'] == 'completed') {
        completed = true;
        evidenceRequire(
          const [
                'success',
                'userRejected',
                'policyDenied',
                'failure',
                'cancelled',
                'indeterminate',
              ].contains(change['outcome_disposition']) &&
              _nonblank(change['model_content']) &&
              const [
                'knownNotOccurred',
                'knownOccurred',
                'uncertain',
              ].contains(change['effect_certainty']) &&
              (change['failure_kind'] == null ||
                  const [
                    'domain',
                    'infrastructure',
                    'staleBinding',
                  ].contains(change['failure_kind'])),
          'Invalid tool outcome.',
        );
      }
    }
  }
  for (final rejected in rows('rejected_proposals')) {
    occurrence(rejected['sequence']);
    origin(rejected, rejected['sequence'] as int, rejected: true);
    evidenceRequire(
      const [
            'unknownAlias',
            'invalidArguments',
            'staleBinding',
            'bindingUnavailable',
          ].contains(rejected['failure_kind']) &&
          _nonblank(rejected['message']),
      'Invalid proposal rejection.',
    );
  }
}

void _effects(Map<String, dynamic> value) {
  evidenceRequire(
    value.keys.toSet().length == 4 &&
        value.keys.toSet().containsAll([
          'effects',
          'targets',
          'summary',
          'uncertainty',
        ]),
    'Invalid effect fields.',
  );
  final effects = value['effects'];
  final targets = value['targets'];
  evidenceRequire(
    effects is List &&
        effects.toSet().length == effects.length &&
        effects.every(
          (e) => const [
            'resourceInspection',
            'sourceRead',
            'sourceMutation',
            'processExecution',
          ].contains(e),
        ) &&
        targets is List &&
        targets.every((t) => t is String && Uri.tryParse(t)?.toString() == t) &&
        _nonblank(value['summary']) &&
        const ['none', 'uncertain'].contains(value['uncertainty']),
    'Invalid effect description.',
  );
}

bool _sameJson(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _sameJson(a[k], b[k]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(a.length, (i) => i).every((i) => _sameJson(a[i], b[i]));
  }
  return a == b;
}
