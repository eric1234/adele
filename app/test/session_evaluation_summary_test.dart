import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import '../tool/session_evaluation_summary.dart';

void main() {
  test(
    'summarizes a completed Session with mixed tools and a command capture',
    () {
      final summary = summarizeSessionEvidence(
        _document(
          runs: [
            _run(
              'run',
              models: [
                _model(
                  'first',
                  1,
                  usage: {
                    'input_tokens': 100,
                    'output_tokens': 20,
                    'cache_read_tokens': 60,
                    'cache_write_tokens': 0,
                  },
                ),
                _model(
                  'last',
                  20,
                  usage: {
                    'input_tokens': 160,
                    'output_tokens': 10,
                    'cache_read_tokens': 80,
                    'cache_write_tokens': 2,
                  },
                ),
              ],
              tools: [
                _tool('read', _fileTool, 3),
                _tool('command', _commandTool, 6),
              ],
              changes: [
                _change('read', 3, 'prepared'),
                _change('read', 4, 'executionStarted'),
                _change('read', 5, 'completed', {
                  'outcome_disposition': 'success',
                }),
                _change('command', 6, 'prepared'),
                _change('command', 7, 'executionStarted'),
                _change('command', 8, 'completed', {
                  'outcome_disposition': 'success',
                }),
              ],
            ),
          ],
          captures: [_capture('run', 'command')],
        ),
      );

      expect(summary['schema'], 'dev.adele.session-evaluation-summary.v1');
      expect(
        summary['source_evidence_schema'],
        'dev.adele.session-evidence.v2',
      );
      expect(summary['session_id'], 'session');
      expect(
        summary['scope'],
        'exported_records_only_not_total_session_consumption',
      );
      expect(summary['coverage'], {
        'status': 'complete_retained_evidence',
        'retained_session_evidence': 'complete_retained_evidence',
        'conversation': 'available',
        'command_transcripts': 'complete_retained_captures',
        'consistency': 'independent_reads_not_atomic_snapshot',
      });
      expect(summary['runs'], {
        'exported_terminal': 1,
        'by_terminal_state': {'completed': 1, 'failed': 0, 'cancelled': 0},
        'associated_without_terminal_evidence': 0,
      });
      expect(summary['models'], {
        'invocations': 2,
        'by_status': {
          'completed': 2,
          'incomplete': 0,
          'refused': 0,
          'failed': 0,
          'no_terminal_record': 0,
        },
        'with_reported_usage': 2,
        'usage': {
          'input_tokens': _usage(260, 2, 2, 'complete'),
          'output_tokens': _usage(30, 2, 2, 'complete'),
          'cache_read_tokens': _usage(140, 2, 2, 'complete'),
          'cache_write_tokens': _usage(2, 2, 2, 'complete'),
        },
      });
      final tools = _map(summary['tools']);
      expect(tools['prepared'], 2);
      expect(tools['observed_execution_starts'], 2);
      expect(tools['recorded_completions'], 2);
      expect(tools['without_completion'], 0);
      expect(_map(tools['by_disposition'])['success'], 2);
      final byTool = _map(tools['by_tool_id']);
      expect(byTool.keys, [_commandTool, _fileTool]);
      for (final counts in byTool.values.map(_map)) {
        expect(counts['prepared'], 1);
        expect(counts['observed_execution_starts'], 1);
        expect(counts['recorded_completions'], 1);
        expect(counts['without_completion'], 0);
        expect(_map(counts['by_disposition'])['success'], 1);
      }
      expect(tools['approvals'], {
        'requests': 0,
        'resolutions': 0,
        'approved': 0,
        'rejected': 0,
        'requests_without_resolution': 0,
      });
      expect(tools['rejected_model_proposals'], 0);
      expect(summary['commands'], {
        'storage_status': 'available',
        'storage_schema_version': 1,
        'captures': 1,
        'by_completeness': {
          'complete': 1,
          'incomplete': 0,
          'unsealed_liveness_unknown': 0,
        },
        'by_terminal_provenance': {
          'matched': 1,
          'terminal_evidence_unavailable': 0,
        },
        'known_nonzero_exits': 0,
        'timeouts': 0,
        'capture_failures': 0,
        'unsealed': 0,
        'invocations_without_capture': {
          'total': 0,
          'by_execution': {'started': 0, 'not_executed': 0, 'not_observed': 0},
        },
      });
      expect(_map(summary['exceptions'])['categories'], isEmpty);
    },
  );

  test(
    'semantic tool success is not reclassified by a nonzero process exit',
    () {
      final summary = summarizeSessionEvidence(
        _document(
          runs: [
            _run(
              'run',
              tools: [_tool('command', _commandTool, 3)],
              changes: [
                _change('command', 3, 'prepared'),
                _change('command', 4, 'executionStarted'),
                _change('command', 5, 'completed', {
                  'outcome_disposition': 'success',
                }),
              ],
            ),
          ],
          captures: [_capture('run', 'command', exitCode: 23)],
        ),
      );

      expect(_map(_map(summary['runs'])['by_terminal_state'])['completed'], 1);
      expect(_map(_map(summary['tools'])['by_disposition']), {
        'success': 1,
        'userRejected': 0,
        'policyDenied': 0,
        'failure': 0,
        'cancelled': 0,
        'indeterminate': 0,
      });
      expect(_map(summary['commands'])['known_nonzero_exits'], 1);
      expect(_map(summary['exceptions'])['categories'], {
        'command_nonzero_exit': {
          'total': 1,
          'omitted': 0,
          'references': [
            {'run_id': 'run', 'tool_invocation_id': 'command', 'exit_code': 23},
          ],
        },
      });
    },
  );

  test(
    'absent usage and a present all-null usage object stay distinguishable',
    () {
      final summary = summarizeSessionEvidence(
        _document(
          runs: [
            _run(
              'run',
              models: [
                _model('absent', 1),
                _model('present-empty', 3, usage: {}),
              ],
            ),
          ],
        ),
      );
      final models = _map(summary['models']);
      expect(models['invocations'], 2);
      expect(models['with_reported_usage'], 1);
      for (final value in _map(models['usage']).values) {
        expect(value, _usage(null, 0, 2, 'none'));
      }
      final run = _rows(_map(summary['context'])['runs']).single;
      expect(run['reported_inputs'], 0);
      expect(run['first_reported_input'], isNull);
      expect(run['last_reported_input'], isNull);
      expect(run['minimum_reported_input'], isNull);
      expect(run['maximum_reported_input'], isNull);
      expect(run['adjacent_pairs'], 1);
      expect(run['pairs_with_reported_inputs'], 0);
      expect(run['pairs_missing_input'], 1);
      expect(run['minimum_input_token_delta'], isNull);
      expect(run['maximum_input_token_delta'], isNull);
    },
  );

  test('known zero is reported complete usage, not missing data', () {
    final summary = summarizeSessionEvidence(
      _document(
        runs: [
          _run(
            'run',
            models: [
              for (var i = 0; i < 2; i++)
                _model(
                  'model-$i',
                  i * 2 + 1,
                  usage: {
                    'input_tokens': 0,
                    'output_tokens': 0,
                    'cache_read_tokens': 0,
                    'cache_write_tokens': 0,
                  },
                ),
            ],
          ),
        ],
      ),
    );
    final models = _map(summary['models']);
    expect(models['with_reported_usage'], 2);
    for (final value in _map(models['usage']).values) {
      expect(value, _usage(0, 2, 2, 'complete'));
    }
    final run = _rows(_map(summary['context'])['runs']).single;
    expect(run['minimum_reported_input'], 0);
    expect(run['maximum_reported_input'], 0);
    expect(run['minimum_input_token_delta'], 0);
    expect(run['maximum_input_token_delta'], 0);
    expect(run['delta_counts'], {'positive': 0, 'zero': 1, 'negative': 0});
  });

  test(
    'each usage counter has its own contributors and full invocation denominator',
    () {
      final summary = summarizeSessionEvidence(
        _document(
          runs: [
            _run(
              'run',
              models: [
                _model('absent', 1),
                _model('empty', 3, usage: {}),
                _model(
                  'zero',
                  5,
                  usage: {'input_tokens': 0, 'cache_read_tokens': 20},
                ),
                _model(
                  'partial',
                  7,
                  usage: {
                    'input_tokens': 7,
                    'output_tokens': 0,
                    'cache_read_tokens': 30,
                  },
                ),
              ],
            ),
          ],
        ),
      );
      final models = _map(summary['models']);
      expect(models['with_reported_usage'], 3);
      expect(models['usage'], {
        'input_tokens': _usage(7, 2, 4, 'partial'),
        'output_tokens': _usage(0, 1, 4, 'partial'),
        'cache_read_tokens': _usage(50, 2, 4, 'partial'),
        'cache_write_tokens': _usage(null, 0, 4, 'none'),
      });
      expect(
        _map(summary['context'])['cache_ratios'],
        'omitted_portable_usage_does_not_define_compatible_denominator',
      );
    },
  );

  test(
    'context is Run-local start order, not IDs, list order or cross-Run chronology',
    () {
      final summary = summarizeSessionEvidence(
        _document(
          runs: [
            _run(
              'run-2',
              models: [
                _model('reused', 1, usage: {'input_tokens': 9999}),
              ],
            ),
            _run(
              'run-10',
              models: [
                _model('a-last', 70, usage: {'input_tokens': 1005}),
                _model('f-grow', 20, usage: {'input_tokens': 30}),
                _model('d-shrink', 40, usage: {'input_tokens': 12}),
                _model('z-first', 10, usage: {'input_tokens': 10}),
                _model('b-after-gap', 60, usage: {'input_tokens': 1000}),
                _model('e-same', 30, usage: {'input_tokens': 30}),
                _model('c-gap', 50),
              ],
            ),
          ],
        ),
      );
      final context = _map(summary['context']);
      expect(
        context['order'],
        'run_local_start_sequence_no_cross_run_chronology',
      );
      expect(
        context['delta_semantics'],
        'adjacent_reported_input_sizes_not_token_attribution',
      );
      final runs = _rows(context['runs']);
      expect(runs.map((run) => run['run_id']), ['run-10', 'run-2']);
      expect(runs.first, {
        'run_id': 'run-10',
        'invocations': 7,
        'reported_inputs': 6,
        'first_reported_input': {
          'model_invocation_id': 'z-first',
          'start_sequence': 10,
          'input_tokens': 10,
        },
        'last_reported_input': {
          'model_invocation_id': 'a-last',
          'start_sequence': 70,
          'input_tokens': 1005,
        },
        'minimum_reported_input': 10,
        'maximum_reported_input': 1005,
        'adjacent_pairs': 6,
        'pairs_with_reported_inputs': 4,
        'pairs_missing_input': 2,
        'minimum_input_token_delta': -18,
        'maximum_input_token_delta': 20,
        'delta_counts': {'positive': 2, 'zero': 1, 'negative': 1},
      });
      expect(runs.last['adjacent_pairs'], 0);
      expect(runs.last['minimum_input_token_delta'], isNull);
      expect(runs.last['maximum_input_token_delta'], isNull);
      expect(context['largest_positive_deltas'], {
        'limit': 10,
        'total': 2,
        'omitted': 0,
        'references': [
          {
            'run_id': 'run-10',
            'from_model_invocation_id': 'z-first',
            'to_model_invocation_id': 'f-grow',
            'from_start_sequence': 10,
            'to_start_sequence': 20,
            'from_input_tokens': 10,
            'to_input_tokens': 30,
            'input_token_delta': 20,
          },
          {
            'run_id': 'run-10',
            'from_model_invocation_id': 'b-after-gap',
            'to_model_invocation_id': 'a-last',
            'from_start_sequence': 60,
            'to_start_sequence': 70,
            'from_input_tokens': 1000,
            'to_input_tokens': 1005,
            'input_token_delta': 5,
          },
        ],
      });
    },
  );

  test(
    'global top ten positive deltas retain exact totals and deterministic ties',
    () {
      const inputs = [0, 10, 20, 25, 30, 34, 37, 39, 40];
      final document = _document(
        runs: [
          for (final runId in ['run-2', 'run-10'])
            _run(
              runId,
              models: [
                for (var i = inputs.length - 1; i >= 0; i--)
                  _model(
                    'model-${100 - i}',
                    (i + 1) * 10,
                    usage: {'input_tokens': inputs[i]},
                  ),
              ],
            ),
        ],
      );
      final summary = summarizeSessionEvidence(document);
      expect(sessionSummaryPositiveDeltaLimit, 10);
      expect(_map(summary['context'])['largest_positive_deltas'], {
        'limit': 10,
        'total': 16,
        'omitted': 6,
        'references': [
          for (final (runId, i) in [
            ('run-10', 1),
            ('run-10', 2),
            ('run-2', 1),
            ('run-2', 2),
            ('run-10', 3),
            ('run-10', 4),
            ('run-2', 3),
            ('run-2', 4),
            ('run-10', 5),
            ('run-2', 5),
          ])
            {
              'run_id': runId,
              'from_model_invocation_id': 'model-${101 - i}',
              'to_model_invocation_id': 'model-${100 - i}',
              'from_start_sequence': i * 10,
              'to_start_sequence': (i + 1) * 10,
              'from_input_tokens': inputs[i - 1],
              'to_input_tokens': inputs[i],
              'input_token_delta': inputs[i] - inputs[i - 1],
            },
        ],
      });
      final shuffled = _map(_shuffled(document, Random(7)));
      expect(
        jsonEncode(summarizeSessionEvidence(shuffled)),
        jsonEncode(summary),
      );
    },
  );

  test('reused model, tool and interruption IDs never join across Runs', () {
    final summary = summarizeSessionEvidence(
      _document(
        runs: [
          _run(
            'run-a',
            models: [
              _model('model', 1, usage: {'input_tokens': 10}),
            ],
            tools: [_tool('tool', _commandTool, 3)],
            changes: [
              _change('tool', 3, 'prepared'),
              _change('tool', 4, 'approvalRequested', {
                'interruption_id': 'approval',
              }),
              _change('tool', 5, 'approvalResolved', {
                'interruption_id': 'approval',
                'approved': 1,
              }),
              _change('tool', 6, 'executionStarted'),
              _change('tool', 7, 'completed', {
                'outcome_disposition': 'success',
              }),
            ],
          ),
          _run(
            'run-b',
            terminalState: 'cancelled',
            models: [
              _model('model', 1, usage: {'input_tokens': 20}),
            ],
            tools: [_tool('tool', _commandTool, 3)],
            changes: [
              _change('tool', 3, 'prepared'),
              _change('tool', 4, 'approvalRequested', {
                'interruption_id': 'approval',
              }),
            ],
          ),
        ],
        captures: [_capture('run-a', 'tool')],
        missingCaptures: [
          {
            'run_id': 'run-b',
            'invocation_id': 'tool',
            'execution': 'not_observed',
          },
        ],
        coverageStatus: 'partial',
        commandCoverage: 'partial',
      ),
    );
    final models = _map(summary['models']);
    expect(models['invocations'], 2);
    expect(_map(models['usage'])['input_tokens'], _usage(30, 2, 2, 'complete'));
    expect(
      _map(_map(summary['context'])['largest_positive_deltas'])['total'],
      0,
    );
    final tools = _map(summary['tools']);
    expect(tools['prepared'], 2);
    expect(tools['observed_execution_starts'], 1);
    expect(tools['recorded_completions'], 1);
    expect(tools['without_completion'], 1);
    expect(tools['approvals'], {
      'requests': 2,
      'resolutions': 1,
      'approved': 1,
      'rejected': 0,
      'requests_without_resolution': 1,
    });
    expect(
      _map(_map(tools['by_tool_id'])[_commandTool])['without_completion'],
      1,
    );
    final categories = _map(_map(summary['exceptions'])['categories']);
    expect(_map(categories['tool_without_completion'])['references'], [
      {'run_id': 'run-b', 'tool_invocation_id': 'tool', 'sequence': 3},
    ]);
    expect(_map(categories['approval_without_resolution'])['references'], [
      {
        'run_id': 'run-b',
        'tool_invocation_id': 'tool',
        'interruption_id': 'approval',
        'sequence': 4,
      },
    ]);
    expect(_map(summary['commands'])['captures'], 1);
    expect(_map(summary['commands'])['invocations_without_capture'], {
      'total': 1,
      'by_execution': {'started': 0, 'not_executed': 0, 'not_observed': 1},
    });
  });

  test(
    'missing terminal Runs and capture-only Runs do not invent execution facts',
    () {
      final summary = summarizeSessionEvidence(
        _document(
          runs: [_run('retained', terminalState: 'cancelled')],
          missingRuns: ['missing-2', 'missing-10'],
          captures: [
            _capture(
              'missing-2',
              'same-tool',
              provenance: 'terminal_evidence_unavailable',
            ),
            _capture(
              'capture-only',
              'same-tool',
              state: 'capturing',
              termination: null,
              exitCode: null,
              provenance: 'terminal_evidence_unavailable',
            ),
            _capture(
              'missing-10',
              'failed-capture',
              state: 'failed',
              termination: 'timedOut',
              exitCode: null,
              provenance: 'terminal_evidence_unavailable',
            ),
          ],
          coverageStatus: 'partial',
          retainedStatus: 'partial',
          commandCoverage: 'partial',
        ),
      );
      expect(summary['runs'], {
        'exported_terminal': 1,
        'by_terminal_state': {'completed': 0, 'failed': 0, 'cancelled': 1},
        'associated_without_terminal_evidence': 2,
      });
      expect(_map(summary['models'])['invocations'], 0);
      expect(_map(summary['tools'])['prepared'], 0);
      final contexts = _rows(_map(summary['context'])['runs']);
      expect(contexts.map((run) => run['run_id']), ['retained']);
      expect(contexts.single['invocations'], 0);
      expect(contexts.single['adjacent_pairs'], 0);
      expect(contexts.single['first_reported_input'], isNull);
      final commands = _map(summary['commands']);
      expect(commands['captures'], 3);
      expect(commands['by_terminal_provenance'], {
        'matched': 0,
        'terminal_evidence_unavailable': 3,
      });
      expect(commands['by_completeness'], {
        'complete': 1,
        'incomplete': 1,
        'unsealed_liveness_unknown': 1,
      });
      expect(commands['known_nonzero_exits'], 0);
      expect(commands['timeouts'], 1);
      expect(commands['capture_failures'], 1);
      expect(commands['unsealed'], 1);
      final categories = _map(_map(summary['exceptions'])['categories']);
      expect(
        _map(
          categories['associated_run_without_terminal_evidence'],
        )['references'],
        [
          {'run_id': 'missing-10'},
          {'run_id': 'missing-2'},
        ],
      );
      expect(
        _map(categories['capture_without_terminal_provenance'])['references'],
        [
          {'run_id': 'capture-only', 'tool_invocation_id': 'same-tool'},
          {'run_id': 'missing-10', 'tool_invocation_id': 'failed-capture'},
          {'run_id': 'missing-2', 'tool_invocation_id': 'same-tool'},
        ],
      );
      expect(_map(categories['capture_incomplete_or_unsealed'])['references'], [
        {
          'run_id': 'capture-only',
          'tool_invocation_id': 'same-tool',
          'completeness': 'unsealed_liveness_unknown',
        },
        {
          'run_id': 'missing-10',
          'tool_invocation_id': 'failed-capture',
          'completeness': 'incomplete',
        },
      ]);
      expect(_map(categories['command_timeout'])['references'], [
        {'run_id': 'missing-10', 'tool_invocation_id': 'failed-capture'},
      ]);
    },
  );

  test('available empty command storage is not unavailable storage', () {
    for (final status in ['available', 'unavailable']) {
      final summary = summarizeSessionEvidence(
        _document(
          commandStatus: status,
          commandCoverage: status == 'available'
              ? 'complete_retained_captures'
              : 'unavailable',
          coverageStatus: status == 'available'
              ? 'complete_retained_evidence'
              : 'partial',
        ),
      );
      final commands = _map(summary['commands']);
      expect(commands['storage_status'], status);
      expect(
        commands['storage_schema_version'],
        status == 'available' ? 1 : null,
      );
      expect(commands['captures'], 0);
      expect(
        _map(summary['coverage'])['command_transcripts'],
        status == 'available' ? 'complete_retained_captures' : 'unavailable',
      );
      expect(
        _map(summary['coverage'])['status'],
        status == 'available' ? 'complete_retained_evidence' : 'partial',
      );
      expect(
        _map(summary['coverage'])['retained_session_evidence'],
        'complete_retained_evidence',
      );
      expect(_map(summary['exceptions'])['categories'], isEmpty);
      for (final value in _map(_map(summary['models'])['usage']).values) {
        expect(value, _usage(null, 0, 0, 'none'));
      }
      expect(_map(summary['context'])['runs'], isEmpty);
    }
  });

  test(
    'failed, refused, incomplete and unterminated models remain distinct',
    () {
      final summary = summarizeSessionEvidence(
        _document(
          runs: [
            _run(
              'run',
              terminalState: 'failed',
              models: [
                _model('success', 1),
                _model('incomplete', 3, settlement: 'incomplete'),
                _model('refused', 5, settlement: 'refused'),
                _model('failed', 7, failureKind: 'providerSpecificDisconnect'),
                _model('unfinished', 9, terminal: false),
              ],
            ),
          ],
        ),
      );
      expect(_map(_map(summary['runs'])['by_terminal_state'])['failed'], 1);
      expect(_map(summary['models'])['by_status'], {
        'completed': 1,
        'incomplete': 1,
        'refused': 1,
        'failed': 1,
        'no_terminal_record': 1,
      });
      final categories = _map(_map(summary['exceptions'])['categories']);
      expect(categories.keys, [
        'model_failed',
        'model_incomplete',
        'model_no_terminal_record',
        'model_refused',
      ]);
      for (final (status, id, start, terminal) in [
        ('incomplete', 'incomplete', 3, 4),
        ('refused', 'refused', 5, 6),
        ('failed', 'failed', 7, 8),
        ('no_terminal_record', 'unfinished', 9, null),
      ]) {
        expect(categories['model_$status'], {
          'total': 1,
          'omitted': 0,
          'references': [
            {
              'run_id': 'run',
              'model_invocation_id': id,
              'sequence': terminal ?? start,
              'start_sequence': start,
              'terminal_sequence': terminal,
            },
          ],
        });
      }
    },
  );

  test(
    'tool outcomes, approvals, policy and rejected proposals are separate observations',
    () {
      const dispositions = [
        'success',
        'userRejected',
        'policyDenied',
        'failure',
        'cancelled',
        'indeterminate',
      ];
      final summary = summarizeSessionEvidence(
        _document(
          runs: [
            _run(
              'run',
              terminalState: 'failed',
              models: [_model('model', 1, terminalSequence: 9)],
              tools: [
                for (var i = 0; i < dispositions.length; i++)
                  _tool(dispositions[i], _fileTool, (i + 1) * 10),
                _tool('pending', _fileTool, 70),
              ],
              changes: [
                for (var i = 0; i < dispositions.length; i++)
                  _change(dispositions[i], (i + 1) * 10, 'prepared'),
                _change('success', 11, 'approvalRequested', {
                  'interruption_id': 'yes',
                }),
                _change('success', 12, 'approvalResolved', {
                  'interruption_id': 'yes',
                  'approved': 1,
                }),
                _change('success', 13, 'executionStarted'),
                _change('success', 14, 'completed', {
                  'outcome_disposition': 'success',
                }),
                _change('userRejected', 21, 'approvalRequested', {
                  'interruption_id': 'no',
                }),
                _change('userRejected', 22, 'approvalResolved', {
                  'interruption_id': 'no',
                  'approved': 0,
                }),
                _change('userRejected', 23, 'completed', {
                  'outcome_disposition': 'userRejected',
                }),
                _change('policyDenied', 31, 'policyEvaluated', {
                  'policy_decision': 'deny',
                }),
                _change('policyDenied', 32, 'completed', {
                  'outcome_disposition': 'policyDenied',
                }),
                _change('failure', 41, 'policyFailed'),
                _change('failure', 42, 'completed', {
                  'outcome_disposition': 'failure',
                }),
                _change('cancelled', 51, 'executionStarted'),
                _change('cancelled', 52, 'completed', {
                  'outcome_disposition': 'cancelled',
                }),
                _change('indeterminate', 61, 'executionStarted'),
                _change('indeterminate', 62, 'completed', {
                  'outcome_disposition': 'indeterminate',
                }),
                _change('pending', 70, 'prepared'),
                _change('pending', 71, 'approvalRequested', {
                  'interruption_id': 'pending',
                }),
              ],
              rejected: [
                {
                  'model_invocation_id': 'model',
                  'sequence': 80,
                  'proposal_sequence': 2,
                  'failure_kind': 'unknownAlias',
                },
                {
                  'model_invocation_id': 'model',
                  'sequence': 81,
                  'proposal_sequence': 3,
                  'failure_kind': 'invalidArguments',
                },
              ],
            ),
          ],
        ),
      );
      final tools = _map(summary['tools']);
      expect(tools['prepared'], 7);
      expect(tools['observed_execution_starts'], 3);
      expect(tools['recorded_completions'], 6);
      expect(tools['by_disposition'], {
        for (final disposition in dispositions) disposition: 1,
      });
      expect(tools['without_completion'], 1);
      expect(tools['rejected_model_proposals'], 2);
      expect(tools['approvals'], {
        'requests': 3,
        'resolutions': 2,
        'approved': 1,
        'rejected': 1,
        'requests_without_resolution': 1,
      });
      final exceptions = _map(summary['exceptions']);
      expect(
        exceptions['semantics'],
        'mechanical_observations_not_defect_classifications_categories_may_overlap',
      );
      final categories = _map(exceptions['categories']);
      expect(categories.keys, [
        'approval_rejected',
        'approval_without_resolution',
        'policy_denied',
        'policy_failed',
        'proposal_rejected',
        'tool_non_success',
        'tool_without_completion',
      ]);
      final expected = <String, List<_Row>>{
        'approval_rejected': [
          {
            'run_id': 'run',
            'tool_invocation_id': 'userRejected',
            'sequence': 22,
            'interruption_id': 'no',
          },
        ],
        'approval_without_resolution': [
          {
            'run_id': 'run',
            'tool_invocation_id': 'pending',
            'sequence': 71,
            'interruption_id': 'pending',
          },
        ],
        'policy_denied': [
          {
            'run_id': 'run',
            'tool_invocation_id': 'policyDenied',
            'sequence': 31,
          },
        ],
        'policy_failed': [
          {'run_id': 'run', 'tool_invocation_id': 'failure', 'sequence': 41},
        ],
        'proposal_rejected': [
          {
            'run_id': 'run',
            'model_invocation_id': 'model',
            'sequence': 80,
            'proposal_sequence': 2,
          },
          {
            'run_id': 'run',
            'model_invocation_id': 'model',
            'sequence': 81,
            'proposal_sequence': 3,
          },
        ],
        'tool_non_success': [
          for (final (id, sequence) in [
            ('userRejected', 23),
            ('policyDenied', 32),
            ('failure', 42),
            ('cancelled', 52),
            ('indeterminate', 62),
          ])
            {
              'run_id': 'run',
              'tool_invocation_id': id,
              'sequence': sequence,
              'outcome_disposition': id,
            },
        ],
        'tool_without_completion': [
          {'run_id': 'run', 'tool_invocation_id': 'pending', 'sequence': 70},
        ],
      };
      for (final entry in expected.entries) {
        expect(categories[entry.key], {
          'total': entry.value.length,
          'omitted': 0,
          'references': entry.value,
        });
      }
    },
  );

  test(
    'missing command captures preserve started, not executed and not observed',
    () {
      final summary = summarizeSessionEvidence(
        _document(
          runs: [
            _run(
              'run',
              tools: [
                _tool('started', _commandTool, 10),
                _tool('denied', _commandTool, 20),
                _tool('unobserved', _commandTool, 30),
              ],
              changes: [
                _change('started', 10, 'prepared'),
                _change('started', 11, 'executionStarted'),
                _change('denied', 20, 'prepared'),
                _change('denied', 21, 'policyEvaluated', {
                  'policy_decision': 'deny',
                }),
                _change('denied', 22, 'completed', {
                  'outcome_disposition': 'policyDenied',
                }),
                _change('unobserved', 30, 'prepared'),
              ],
            ),
          ],
          missingCaptures: [
            {
              'run_id': 'run',
              'invocation_id': 'started',
              'execution': 'started',
            },
            {
              'run_id': 'run',
              'invocation_id': 'unobserved',
              'execution': 'not_observed',
            },
            {
              'run_id': 'run',
              'invocation_id': 'denied',
              'execution': 'not_executed',
            },
          ],
          coverageStatus: 'partial',
          commandCoverage: 'partial',
        ),
      );
      expect(_map(summary['commands'])['invocations_without_capture'], {
        'total': 3,
        'by_execution': {'started': 1, 'not_executed': 1, 'not_observed': 1},
      });
      expect(
        _map(
          _map(
            _map(summary['exceptions'])['categories'],
          )['command_without_capture'],
        )['references'],
        [
          {
            'run_id': 'run',
            'tool_invocation_id': 'denied',
            'execution': 'not_executed',
          },
          {
            'run_id': 'run',
            'tool_invocation_id': 'started',
            'execution': 'started',
          },
          {
            'run_id': 'run',
            'tool_invocation_id': 'unobserved',
            'execution': 'not_observed',
          },
        ],
      );
    },
  );

  test(
    'large exception sets bound each category, retain exact references and never mutate evidence',
    () {
      final document = _document(
        runs: [
          for (final runId in ['run-2', 'run-10'])
            _run(
              runId,
              terminalState: 'failed',
              models: [
                for (var i = 13; i >= 1; i--)
                  _model(
                    'model-${100 - i}',
                    i * 10 + 1,
                    failureKind: 'transport',
                  ),
              ],
              tools: [
                for (var i = 13; i >= 1; i--)
                  _tool('tool-${100 - i}', _commandTool, i * 10 + 3),
              ],
              changes: [
                for (var i = 13; i >= 1; i--) ...[
                  _change('tool-${100 - i}', i * 10 + 3, 'prepared'),
                  _change('tool-${100 - i}', i * 10 + 4, 'executionStarted'),
                ],
              ],
            ),
        ],
        missingRuns: [for (var i = 1; i <= 26; i++) 'missing-${100 - i}'],
        captures: [
          for (final runId in ['outside-2', 'outside-10'])
            for (var i = 1; i <= 13; i++)
              _capture(
                runId,
                'tool-${100 - i}',
                state: 'failed',
                exitCode: 23,
                provenance: 'terminal_evidence_unavailable',
              ),
        ],
        missingCaptures: [
          for (final runId in ['run-2', 'run-10'])
            for (var i = 1; i <= 13; i++)
              {
                'run_id': runId,
                'invocation_id': 'tool-${100 - i}',
                'execution': 'started',
              },
        ],
        coverageStatus: 'partial',
        retainedStatus: 'partial',
        commandCoverage: 'partial',
      );
      final original = jsonEncode(document);
      final summary = summarizeSessionEvidence(document);
      final exceptions = _map(summary['exceptions']);
      expect(sessionSummaryExceptionReferenceLimit, 20);
      expect(exceptions['reference_limit_per_category'], 20);
      expect(
        exceptions['order'],
        'category_then_lexical_run_id_then_sequence_then_invocation_id_not_chronology',
      );
      final categories = _map(exceptions['categories']);
      final expected = <String, List<_Row>>{
        'associated_run_without_terminal_evidence': [
          for (var i = 26; i >= 1; i--) {'run_id': 'missing-${100 - i}'},
        ],
        'capture_incomplete_or_unsealed': [
          for (final runId in ['outside-10', 'outside-2'])
            for (var i = 13; i >= 1; i--)
              {
                'run_id': runId,
                'tool_invocation_id': 'tool-${100 - i}',
                'completeness': 'incomplete',
              },
        ],
        'capture_without_terminal_provenance': [
          for (final runId in ['outside-10', 'outside-2'])
            for (var i = 13; i >= 1; i--)
              {'run_id': runId, 'tool_invocation_id': 'tool-${100 - i}'},
        ],
        'command_nonzero_exit': [
          for (final runId in ['outside-10', 'outside-2'])
            for (var i = 13; i >= 1; i--)
              {
                'run_id': runId,
                'tool_invocation_id': 'tool-${100 - i}',
                'exit_code': 23,
              },
        ],
        'command_without_capture': [
          for (final runId in ['run-10', 'run-2'])
            for (var i = 13; i >= 1; i--)
              {
                'run_id': runId,
                'tool_invocation_id': 'tool-${100 - i}',
                'execution': 'started',
              },
        ],
        'model_failed': [
          for (final runId in ['run-10', 'run-2'])
            for (var i = 1; i <= 13; i++)
              {
                'run_id': runId,
                'model_invocation_id': 'model-${100 - i}',
                'sequence': i * 10 + 2,
                'start_sequence': i * 10 + 1,
                'terminal_sequence': i * 10 + 2,
              },
        ],
        'tool_without_completion': [
          for (final runId in ['run-10', 'run-2'])
            for (var i = 1; i <= 13; i++)
              {
                'run_id': runId,
                'tool_invocation_id': 'tool-${100 - i}',
                'sequence': i * 10 + 3,
              },
        ],
      };
      expect(categories.keys, expected.keys);
      for (final entry in expected.entries) {
        expect(categories[entry.key], {
          'total': 26,
          'omitted': 6,
          'references': entry.value.take(20).toList(),
        }, reason: entry.key);
      }
      expect(_map(summary['models'])['invocations'], 26);
      expect(_map(summary['tools'])['without_completion'], 26);
      expect(_map(summary['commands'])['known_nonzero_exits'], 26);
      expect(jsonEncode(document), original);
      final encoded = jsonEncode(summary);
      expect(jsonEncode(summarizeSessionEvidence(document)), encoded);
      for (var seed = 0; seed < 5; seed++) {
        final shuffled = _map(_shuffled(document, Random(seed)));
        final before = jsonEncode(shuffled);
        expect(
          jsonEncode(summarizeSessionEvidence(shuffled)),
          encoded,
          reason: 'seed $seed',
        );
        expect(
          jsonEncode(shuffled),
          before,
          reason: 'source mutation, seed $seed',
        );
      }
      expect(jsonEncode(document), original);
    },
  );

  test(
    'summary copies no conversation, prompt, arguments, transcript or result payload',
    () {
      const sentinels = [
        'PRIVATE-PROMPT',
        'PRIVATE-CONVERSATION',
        'PRIVATE-MODEL-OUTPUT',
        'PRIVATE-ARGUMENTS',
        'PRIVATE-RESULT',
        'PRIVATE-HOST-DATA',
        'PRIVATE-TRANSCRIPT',
        'PRIVATE-APPROVAL-PROMPT',
        'PRIVATE-PROPOSAL',
        'PRIVATE-USAGE-DETAILS',
        'PRIVATE-FAILURE-MESSAGE',
      ];
      final command = _tool('command', _commandTool, 10)
        ..['canonical_arguments_json'] = '{"shellCommand":"PRIVATE-ARGUMENTS"}';
      final model = _model(
        'model',
        1,
        terminalSequence: 9,
        usage: {'input_tokens': 5},
      )..['usage_provider_details_json'] = '{"detail":"PRIVATE-USAGE-DETAILS"}';
      final run = _run(
        'run',
        models: [model],
        tools: [command],
        changes: [
          _change('command', 10, 'prepared'),
          _change('command', 11, 'approvalRequested', {
            'interruption_id': 'approval',
            'effects_json': '{"summary":"PRIVATE-APPROVAL-PROMPT"}',
          }),
          _change('command', 12, 'approvalResolved', {
            'interruption_id': 'approval',
            'approved': 1,
          }),
          _change('command', 13, 'executionStarted'),
          _change('command', 14, 'completed', {
            'outcome_disposition': 'success',
            'model_content': 'PRIVATE-RESULT',
            'host_data_json': '{"detail":"PRIVATE-HOST-DATA"}',
          }),
        ],
        rejected: [
          {
            'model_invocation_id': 'model',
            'sequence': 15,
            'proposal_sequence': 3,
            'arguments_json': '{"detail":"PRIVATE-PROPOSAL"}',
            'message': 'PRIVATE-FAILURE-MESSAGE',
          },
        ],
      );
      _map(run['evidence'])['model_outputs'] = [
        {
          'model_invocation_id': 'model',
          'sequence': 2,
          'kind': 'text',
          'text_content': 'PRIVATE-MODEL-OUTPUT',
        },
        {
          'model_invocation_id': 'model',
          'sequence': 3,
          'kind': 'toolProposal',
          'arguments_json': '{"detail":"PRIVATE-PROPOSAL"}',
        },
      ];
      final capture = _capture('run', 'command');
      _map(capture['header'])['arguments_json'] =
          '{"shellCommand":"PRIVATE-ARGUMENTS"}';
      capture['chunks'] = [
        {'position': 1, 'stream': 'stdout', 'text': 'PRIVATE-TRANSCRIPT'},
      ];
      final document = _document(runs: [run], captures: [capture]);
      _map(document['conversation']).addAll({
        'configuration': {'instructions': 'PRIVATE-PROMPT'},
        'entries': [
          {'sequence': 1, 'role': 'user', 'content': 'PRIVATE-CONVERSATION'},
        ],
      });
      final before = jsonEncode(document);
      final summary = summarizeSessionEvidence(document);
      final encoded = jsonEncode(summary);
      for (final sentinel in sentinels) {
        expect(before, contains(sentinel));
        expect(encoded, isNot(contains(sentinel)));
      }
      for (final key in [
        'configuration',
        'instructions',
        'entries',
        'model_outputs',
        'text_content',
        'canonical_arguments_json',
        'arguments_json',
        'model_content',
        'host_data_json',
        'chunks',
        'effects_json',
        'usage_provider_details_json',
        'message',
      ]) {
        expect(encoded, isNot(contains('"$key":')));
      }
      expect(_map(summary['models'])['invocations'], 1);
      expect(_map(summary['tools'])['recorded_completions'], 1);
      expect(_map(summary['commands'])['captures'], 1);
      expect(jsonEncode(document), before);
    },
  );

  test(
    'token totals preserve the native integer limit and fail closed on overflow',
    () {
      const maximum = 0x7fffffffffffffff;
      for (final field in [
        'input_tokens',
        'output_tokens',
        'cache_read_tokens',
        'cache_write_tokens',
      ]) {
        final models = [
          _model('maximum', 1, usage: {field: maximum}),
        ];
        final document = _document(runs: [_run('run', models: models)]);
        final summary = summarizeSessionEvidence(document);
        expect(
          _map(_map(summary['models'])['usage'])[field],
          _usage(maximum, 1, 1, 'complete'),
        );
        models.add(_model('overflow', 3, usage: {field: 1}));
        final before = jsonEncode(document);
        expect(
          () => summarizeSessionEvidence(document),
          throwsFormatException,
          reason: field,
        );
        expect(jsonEncode(document), before);
      }
    },
  );

  test('rejects incompatible schemas before projecting any evidence', () {
    for (final schema in [
      null,
      'dev.adele.session-evidence.v1',
      'dev.adele.session-evidence.v3',
      'dev.adele.session-evaluation-summary.v1',
    ]) {
      expect(
        () => summarizeSessionEvidence({'schema': schema}),
        throwsFormatException,
      );
    }
  });
}

// This unit boundary assumes already-validated v2 evidence. Fixtures retain only
// the selected fields relevant to projection, not the backend SQL/graph validator
// fixture. In particular null counters are unreported and presence is independent.
typedef _Row = Map<String, Object?>;

const _commandTool = 'dev.adele.plugin.command-tools.run-command';
const _fileTool = 'test.read-file';

_Row _document({
  List<_Row> runs = const [],
  List<_Row> captures = const [],
  List<String> missingRuns = const [],
  List<_Row> missingCaptures = const [],
  String commandStatus = 'available',
  String commandCoverage = 'complete_retained_captures',
  String coverageStatus = 'complete_retained_evidence',
  String retainedStatus = 'complete_retained_evidence',
}) => {
  'schema': 'dev.adele.session-evidence.v2',
  'identity': {'session_id': 'session'},
  'conversation': <String, Object?>{'status': 'available'},
  'runs': runs,
  'command_tools': {
    'status': commandStatus,
    'schema_version': commandStatus == 'available' ? 1 : null,
    'captures': captures,
  },
  'coverage': {
    'status': coverageStatus,
    'retained_session_evidence': retainedStatus,
    'command_transcripts': {
      'status': commandCoverage,
      'invocations_without_capture': missingCaptures,
    },
    'consistency': 'independent_reads_not_atomic_snapshot',
    'run_order': 'lexical_id_not_chronology',
    'associated_runs_without_terminal_evidence': missingRuns,
  },
};

_Row _run(
  String id, {
  String terminalState = 'completed',
  List<_Row> models = const [],
  List<_Row> tools = const [],
  List<_Row> changes = const [],
  List<_Row> rejected = const [],
}) => {
  'id': id,
  'terminal_state': terminalState,
  'evidence': <String, Object?>{
    'model_invocations': models,
    'tool_invocations': tools,
    'tool_changes': changes,
    'rejected_proposals': rejected,
  },
};

_Row _model(
  String id,
  int start, {
  Map<String, int?>? usage,
  String settlement = 'completed',
  String? failureKind,
  bool terminal = true,
  int? terminalSequence,
}) => {
  'invocation_id': id,
  'start_sequence': start,
  'terminal_sequence': terminal ? terminalSequence ?? start + 1 : null,
  'settlement': terminal && failureKind == null ? settlement : null,
  'incomplete_reason': settlement == 'incomplete' ? 'outputLimit' : null,
  'failure_kind': failureKind,
  'metadata_present': terminal && failureKind == null ? 1 : 0,
  'usage_present': usage == null ? 0 : 1,
  'usage_provider_details_json': usage == null ? null : '{}',
  for (final field in [
    'input_tokens',
    'output_tokens',
    'cache_read_tokens',
    'cache_write_tokens',
  ])
    field: usage?[field],
};

_Row _tool(String id, String toolId, int prepared) => {
  'invocation_id': id,
  'tool_id': toolId,
  'prepared_sequence': prepared,
};

_Row _change(String id, int sequence, String kind, [_Row payload = const {}]) =>
    {'tool_invocation_id': id, 'sequence': sequence, 'kind': kind, ...payload};

_Row _capture(
  String runId,
  String id, {
  String state = 'complete',
  String? termination = 'exited',
  int? exitCode = 0,
  String provenance = 'matched',
}) => {
  'header': <String, Object?>{
    'run_id': runId,
    'invocation_id': id,
    'state': state,
    'termination': termination,
    'exit_code': exitCode,
    'failure': state == 'failed' ? 'Capture failed.' : null,
  },
  'completeness': switch (state) {
    'complete' => 'complete',
    'failed' => 'incomplete',
    _ => 'unsealed_liveness_unknown',
  },
  'terminal_provenance': provenance,
};

_Row _usage(int? total, int contributors, int denominator, String coverage) => {
  'reported_total': total,
  'contributing_invocations': contributors,
  'denominator_invocations': denominator,
  'coverage': coverage,
};

_Row _map(Object? value) => value as _Row;
List<_Row> _rows(Object? value) => (value as List).cast<_Row>();

Object? _shuffled(Object? value, Random random) {
  if (value is _Row) {
    final keys = value.keys.toList()..shuffle(random);
    return <String, Object?>{
      for (final key in keys) key: _shuffled(value[key], random),
    };
  }
  if (value is List) {
    return [for (final item in value) _shuffled(item, random)]..shuffle(random);
  }
  return value;
}
