const sessionEvaluationSummarySchema =
    'dev.adele.session-evaluation-summary.v1';
const sessionSummaryExceptionReferenceLimit = 20;
const sessionSummaryPositiveDeltaLimit = 10;

/// Pure projection of the already validated document from readSessionEvidence.
/// This does not validate backend relationships again, query storage, or mutate
/// evidence. Pin the input schema explicitly rather than following future versions.
Map<String, Object?> summarizeSessionEvidence(Map<String, Object?> document) {
  if (document['schema'] != 'dev.adele.session-evidence.v2') {
    throw const FormatException('Unsupported summary source evidence schema.');
  }
  final coverage = _map(document['coverage']);
  final commandCoverage = _map(coverage['command_transcripts']);
  final commands = _map(document['command_tools']);
  final runs = _rows(document['runs']).toList()
    ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
  final missingRuns =
      coverage['associated_runs_without_terminal_evidence'] as List;
  final exceptions = _ExceptionIndex();
  final runStates = {'completed': 0, 'failed': 0, 'cancelled': 0};
  final modelStates = {
    'completed': 0,
    'incomplete': 0,
    'refused': 0,
    'failed': 0,
    'no_terminal_record': 0,
  };
  var modelCount = 0;
  var withUsage = 0;
  const tokenFields = [
    'input_tokens',
    'output_tokens',
    'cache_read_tokens',
    'cache_write_tokens',
  ];
  final tokenTotals = {for (final field in tokenFields) field: 0};
  final tokenCounts = {for (final field in tokenFields) field: 0};
  final contextRuns = <Map<String, Object?>>[];
  final positiveDeltas = <Map<String, Object?>>[];
  var positiveDeltaCount = 0;
  final toolTotals = _ToolCounts();
  final toolsById = <String, _ToolCounts>{};
  var approvalRequests = 0;
  var approvalsApproved = 0;
  var approvalsRejected = 0;
  var approvalsWithoutResolution = 0;
  var rejectedProposals = 0;

  for (final run in runs) {
    final runId = run['id'] as String;
    _increment(runStates, run['terminal_state'] as String);
    final evidence = _map(run['evidence']);
    final models = _rows(evidence['model_invocations']).toList()
      ..sort(
        (a, b) =>
            (a['start_sequence'] as int).compareTo(b['start_sequence'] as int),
      );
    Map<String, Object?>? firstInput;
    Map<String, Object?>? lastInput;
    int? minInput;
    int? maxInput;
    int? minDelta;
    int? maxDelta;
    var reportedInputs = 0;
    var reportedPairs = 0;
    final deltaSigns = {'positive': 0, 'zero': 0, 'negative': 0};
    Map<String, Object?>? previous;
    for (final model in models) {
      modelCount++;
      final status = model['terminal_sequence'] == null
          ? 'no_terminal_record'
          : model['failure_kind'] != null
          ? 'failed'
          : model['settlement'] as String;
      _increment(modelStates, status);
      if (status != 'completed') {
        exceptions.add('model_$status', {
          'run_id': runId,
          'model_invocation_id': model['invocation_id'],
          'sequence': model['terminal_sequence'] ?? model['start_sequence'],
          'start_sequence': model['start_sequence'],
          'terminal_sequence': model['terminal_sequence'],
        });
      }
      if (model['usage_present'] == 1) withUsage++;
      for (final field in tokenFields) {
        if (model[field] case final int value) {
          final total = tokenTotals[field]! + value;
          if (total < 0) {
            throw const FormatException(
              'Reported token total exceeds integer range.',
            );
          }
          tokenTotals[field] = total;
          tokenCounts[field] = tokenCounts[field]! + 1;
        }
      }
      final input = model['input_tokens'] as int?;
      if (input != null) {
        reportedInputs++;
        final observation = <String, Object?>{
          'model_invocation_id': model['invocation_id'],
          'start_sequence': model['start_sequence'],
          'input_tokens': input,
        };
        firstInput ??= observation;
        lastInput = observation;
        if (minInput == null || input < minInput) minInput = input;
        if (maxInput == null || input > maxInput) maxInput = input;
        final priorInput = previous?['input_tokens'] as int?;
        if (priorInput != null) {
          final delta = input - priorInput;
          reportedPairs++;
          if (minDelta == null || delta < minDelta) minDelta = delta;
          if (maxDelta == null || delta > maxDelta) maxDelta = delta;
          _increment(
            deltaSigns,
            delta > 0
                ? 'positive'
                : delta < 0
                ? 'negative'
                : 'zero',
          );
          if (delta > 0) {
            positiveDeltaCount++;
            positiveDeltas.add({
              'run_id': runId,
              'from_model_invocation_id': previous!['invocation_id'],
              'to_model_invocation_id': model['invocation_id'],
              'from_start_sequence': previous['start_sequence'],
              'to_start_sequence': model['start_sequence'],
              'from_input_tokens': priorInput,
              'to_input_tokens': input,
              'input_token_delta': delta,
            });
            positiveDeltas.sort((a, b) {
              final size = (b['input_token_delta'] as int).compareTo(
                a['input_token_delta'] as int,
              );
              if (size != 0) return size;
              final run = (a['run_id'] as String).compareTo(
                b['run_id'] as String,
              );
              return run != 0
                  ? run
                  : (a['to_start_sequence'] as int).compareTo(
                      b['to_start_sequence'] as int,
                    );
            });
            if (positiveDeltas.length > sessionSummaryPositiveDeltaLimit) {
              positiveDeltas.removeLast();
            }
          }
        }
      }
      // Keep the actual adjacent invocation, including one with missing usage.
      previous = model;
    }
    final pairs = models.isEmpty ? 0 : models.length - 1;
    contextRuns.add({
      'run_id': runId,
      'invocations': models.length,
      'reported_inputs': reportedInputs,
      'first_reported_input': firstInput,
      'last_reported_input': lastInput,
      'minimum_reported_input': minInput,
      'maximum_reported_input': maxInput,
      'adjacent_pairs': pairs,
      'pairs_with_reported_inputs': reportedPairs,
      'pairs_missing_input': pairs - reportedPairs,
      'minimum_input_token_delta': minDelta,
      'maximum_input_token_delta': maxDelta,
      'delta_counts': deltaSigns,
    });

    // Invocation IDs are only unique inside this Run.
    final tools = {
      for (final tool in _rows(evidence['tool_invocations']))
        tool['invocation_id'] as String: tool,
    };
    final completed = <String>{};
    final changes = _rows(evidence['tool_changes']);
    final resolvedApprovals = <(String, String)>{};
    for (final tool in tools.values) {
      toolTotals.prepared++;
      (toolsById[tool['tool_id'] as String] ??= _ToolCounts()).prepared++;
    }
    for (final change in changes) {
      final toolId = change['tool_invocation_id'] as String;
      final tool = tools[toolId]!;
      final counts = toolsById[tool['tool_id'] as String]!;
      final reference = <String, Object?>{
        'run_id': runId,
        'tool_invocation_id': toolId,
        'sequence': change['sequence'],
      };
      switch (change['kind']) {
        case 'executionStarted':
          toolTotals.executionStarts++;
          counts.executionStarts++;
        case 'completed':
          completed.add(toolId);
          final disposition = change['outcome_disposition'] as String;
          _increment(toolTotals.dispositions, disposition);
          _increment(counts.dispositions, disposition);
          if (disposition != 'success') {
            exceptions.add('tool_non_success', {
              ...reference,
              'outcome_disposition': disposition,
            });
          }
        case 'approvalRequested':
          approvalRequests++;
        case 'approvalResolved':
          resolvedApprovals.add((toolId, change['interruption_id'] as String));
          if (change['approved'] == 1) {
            approvalsApproved++;
          } else {
            approvalsRejected++;
            exceptions.add('approval_rejected', {
              ...reference,
              'interruption_id': change['interruption_id'],
            });
          }
        case 'policyEvaluated':
          if (change['policy_decision'] == 'deny') {
            exceptions.add('policy_denied', reference);
          }
        case 'policyFailed':
          exceptions.add('policy_failed', reference);
      }
    }
    for (final change in changes) {
      if (change['kind'] == 'approvalRequested' &&
          !resolvedApprovals.contains((
            change['tool_invocation_id'] as String,
            change['interruption_id'] as String,
          ))) {
        approvalsWithoutResolution++;
        exceptions.add('approval_without_resolution', {
          'run_id': runId,
          'tool_invocation_id': change['tool_invocation_id'],
          'interruption_id': change['interruption_id'],
          'sequence': change['sequence'],
        });
      }
    }
    for (final tool in tools.values) {
      if (!completed.contains(tool['invocation_id'])) {
        toolTotals.withoutCompletion++;
        toolsById[tool['tool_id'] as String]!.withoutCompletion++;
        exceptions.add('tool_without_completion', {
          'run_id': runId,
          'tool_invocation_id': tool['invocation_id'],
          'sequence': tool['prepared_sequence'],
        });
      }
    }
    for (final proposal in _rows(evidence['rejected_proposals'])) {
      rejectedProposals++;
      exceptions.add('proposal_rejected', {
        'run_id': runId,
        'model_invocation_id': proposal['model_invocation_id'],
        'sequence': proposal['sequence'],
        'proposal_sequence': proposal['proposal_sequence'],
      });
    }
  }

  final completeness = {
    'complete': 0,
    'incomplete': 0,
    'unsealed_liveness_unknown': 0,
  };
  final provenance = {'matched': 0, 'terminal_evidence_unavailable': 0};
  var captures = 0;
  var nonzeroExits = 0;
  var timeouts = 0;
  var captureFailures = 0;
  var unsealed = 0;
  for (final capture in _rows(commands['captures'])) {
    captures++;
    _increment(completeness, capture['completeness'] as String);
    _increment(provenance, capture['terminal_provenance'] as String);
    final header = _map(capture['header']);
    final reference = <String, Object?>{
      'run_id': header['run_id'],
      'tool_invocation_id': header['invocation_id'],
    };
    if (header['exit_code'] case final int exit when exit != 0) {
      nonzeroExits++;
      exceptions.add('command_nonzero_exit', {...reference, 'exit_code': exit});
    }
    if (header['termination'] == 'timedOut') {
      timeouts++;
      exceptions.add('command_timeout', reference);
    }
    if (header['state'] == 'failed') captureFailures++;
    if (header['state'] == 'capturing') unsealed++;
    if (capture['completeness'] != 'complete') {
      exceptions.add('capture_incomplete_or_unsealed', {
        ...reference,
        'completeness': capture['completeness'],
      });
    }
    if (capture['terminal_provenance'] != 'matched') {
      exceptions.add('capture_without_terminal_provenance', reference);
    }
  }
  final missingCaptures = {'started': 0, 'not_executed': 0, 'not_observed': 0};
  var missingCaptureCount = 0;
  for (final missing in _rows(commandCoverage['invocations_without_capture'])) {
    missingCaptureCount++;
    _increment(missingCaptures, missing['execution'] as String);
    exceptions.add('command_without_capture', {
      'run_id': missing['run_id'],
      'tool_invocation_id': missing['invocation_id'],
      'execution': missing['execution'],
    });
  }
  for (final runId in missingRuns) {
    exceptions.add('associated_run_without_terminal_evidence', {
      'run_id': runId,
    });
  }

  final canonicalToolIds = toolsById.keys.toList()..sort();
  return {
    'schema': sessionEvaluationSummarySchema,
    'source_evidence_schema': document['schema'],
    'session_id': _map(document['identity'])['session_id'],
    'scope': 'exported_records_only_not_total_session_consumption',
    'coverage': {
      'status': coverage['status'],
      'retained_session_evidence': coverage['retained_session_evidence'],
      'conversation': _map(document['conversation'])['status'],
      'command_transcripts': commandCoverage['status'],
      'consistency': coverage['consistency'],
    },
    'runs': {
      'exported_terminal': runs.length,
      'by_terminal_state': runStates,
      'associated_without_terminal_evidence': missingRuns.length,
    },
    'models': {
      'invocations': modelCount,
      'by_status': modelStates,
      'with_reported_usage': withUsage,
      'usage': {
        for (final field in tokenFields)
          field: {
            'reported_total': tokenCounts[field] == 0
                ? null
                : tokenTotals[field],
            'contributing_invocations': tokenCounts[field],
            'denominator_invocations': modelCount,
            'coverage': tokenCounts[field] == 0
                ? 'none'
                : tokenCounts[field] == modelCount
                ? 'complete'
                : 'partial',
          },
      },
    },
    'context': {
      'order': 'run_local_start_sequence_no_cross_run_chronology',
      'delta_semantics': 'adjacent_reported_input_sizes_not_token_attribution',
      'cache_ratios':
          'omitted_portable_usage_does_not_define_compatible_denominator',
      'runs': contextRuns,
      'largest_positive_deltas': {
        'limit': sessionSummaryPositiveDeltaLimit,
        'total': positiveDeltaCount,
        'omitted': positiveDeltaCount - positiveDeltas.length,
        'references': positiveDeltas,
      },
    },
    'tools': {
      ...toolTotals.toJson(),
      'by_tool_id': {
        for (final id in canonicalToolIds) id: toolsById[id]!.toJson(),
      },
      'approvals': {
        'requests': approvalRequests,
        'resolutions': approvalsApproved + approvalsRejected,
        'approved': approvalsApproved,
        'rejected': approvalsRejected,
        'requests_without_resolution': approvalsWithoutResolution,
      },
      'rejected_model_proposals': rejectedProposals,
    },
    'commands': {
      'storage_status': commands['status'],
      'storage_schema_version': commands['schema_version'],
      'captures': captures,
      'by_completeness': completeness,
      'by_terminal_provenance': provenance,
      'known_nonzero_exits': nonzeroExits,
      'timeouts': timeouts,
      'capture_failures': captureFailures,
      'unsealed': unsealed,
      'invocations_without_capture': {
        'total': missingCaptureCount,
        'by_execution': missingCaptures,
      },
    },
    'exceptions': exceptions.toJson(),
  };
}

Map<String, Object?> _map(Object? value) => value as Map<String, Object?>;
Iterable<Map<String, Object?>> _rows(Object? value) =>
    (value as List).cast<Map<String, Object?>>();
void _increment(Map<String, int> counts, String key) =>
    counts[key] = (counts[key] ?? 0) + 1;

final class _ToolCounts {
  var prepared = 0;
  var executionStarts = 0;
  var withoutCompletion = 0;
  final dispositions = {
    'success': 0,
    'userRejected': 0,
    'policyDenied': 0,
    'failure': 0,
    'cancelled': 0,
    'indeterminate': 0,
  };
  Map<String, Object?> toJson() => {
    'prepared': prepared,
    'observed_execution_starts': executionStarts,
    'recorded_completions': dispositions.values.fold<int>(0, (a, b) => a + b),
    'by_disposition': dispositions,
    'without_completion': withoutCompletion,
  };
}

final class _ExceptionIndex {
  final _counts = <String, int>{};
  final _references = <String, List<Map<String, Object?>>>{};

  void add(String category, Map<String, Object?> reference) {
    _increment(_counts, category);
    final selected = _references.putIfAbsent(category, () => []);
    selected.add(reference);
    selected.sort((a, b) {
      for (final field in [
        'run_id',
        'sequence',
        'tool_invocation_id',
        'model_invocation_id',
      ]) {
        final left = a[field];
        final right = b[field];
        final comparison = field == 'sequence'
            ? ((left as int?) ?? -1).compareTo((right as int?) ?? -1)
            : ((left as String?) ?? '').compareTo((right as String?) ?? '');
        if (comparison != 0) return comparison;
      }
      return 0;
    });
    if (selected.length > sessionSummaryExceptionReferenceLimit) {
      selected.removeLast();
    }
  }

  Map<String, Object?> toJson() {
    final categories = _counts.keys.toList()..sort();
    return {
      'semantics':
          'mechanical_observations_not_defect_classifications_categories_may_overlap',
      'order':
          'category_then_lexical_run_id_then_sequence_then_invocation_id_not_chronology',
      'reference_limit_per_category': sessionSummaryExceptionReferenceLimit,
      'categories': {
        for (final category in categories)
          category: {
            'total': _counts[category],
            'omitted': _counts[category]! - _references[category]!.length,
            'references': _references[category],
          },
      },
    };
  }
}
