import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/execution_evidence.dart';
import 'package:adele_desktop/core/project_database.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

const _tables = [
  'run_activity',
  'run_lifecycle',
  'model_invocations',
  'model_outputs',
  'tool_invocations',
  'tool_changes',
  'rejected_proposals',
];

void main() {
  late ProjectDatabase database;
  late Database inspection;
  late ProjectBacking backing;
  late RunRecord record;
  late RunActivitySnapshot activity;

  setUp(() {
    final source = Directory.systemTemp.createTempSync('adele-evidence-');
    addTearDown(() => source.deleteSync(recursive: true));
    backing = ProjectBacking(
      sourceLocation: source.uri,
      databaseRelativePath: 'project.sqlite',
    );
    database = ProjectDatabase.open(backing);
    addTearDown(() => database.close());
    final project = database.openProject(
      sourceLocation: source.uri,
      nextProjectId: () => ProjectId('project'),
    );
    final task = Task(
      id: TaskId('task'),
      projectId: project.id,
      title: 'Evidence',
    );
    final environment = Environment(
      id: EnvironmentId('environment'),
      taskId: task.id,
      role: EnvironmentRole.primary,
      providerId: ProviderId('test.environment'),
      providerState: {},
    );
    database.insertTaskWithPrimaryEnvironment(task, environment);
    final session = Session(
      id: SessionId('session'),
      taskId: task.id,
      strategyId: OrchestrationStrategyId('test.strategy'),
    );
    database.insertSessionWithAuthority(session, environment.id);
    record = RunRecord(
      id: RunId('run'),
      sessionId: session.id,
      state: RunTerminalState.failed,
    );
    activity = _fixture(record);
    inspection = sqlite3.open(database.path);
    addTearDown(() => inspection.close());
  });

  List<RunActivitySnapshot> load() =>
      database.loadExecutionHistory(database.loadProductGraph().runRecords);

  test(
    'relational baseline has no root state/Session or whole-snapshot JSON',
    () {
      expect(
        inspection.select(
          'SELECT * FROM adele_schema_versions ORDER BY owner_id',
        ),
        [
          {'owner_id': 'dev.adele.execution', 'version': 1},
          {'owner_id': 'dev.adele.product', 'version': 1},
        ],
      );
      expect(
        inspection
            .select('PRAGMA table_info(adele_execution_run_activity)')
            .map((row) => row['name']),
        [
          'run_id',
          'latest_sequence',
          'failure_kind',
          'failure_message',
          'failure_provider_code',
          'failure_provider_details_json',
        ],
      );
      const jsonColumns = {
        'run_activity': ['failure_provider_details_json'],
        'run_lifecycle': <String>[],
        'model_invocations': [
          'usage_provider_details_json',
          'native_state_compatibility_json',
          'native_state_data_json',
          'failure_provider_details_json',
        ],
        'model_outputs': [
          'native_metadata_compatibility_json',
          'native_metadata_data_json',
          'presentation_data_json',
          'arguments_json',
        ],
        'tool_invocations': ['canonical_arguments_json'],
        'tool_changes': ['effects_json', 'host_data_json'],
        'rejected_proposals': ['arguments_json'],
      };
      for (final table in _tables) {
        expect(
          inspection.select('PRAGMA foreign_key_list(adele_execution_$table)'),
          isNotEmpty,
        );
        expect(
          inspection
              .select('PRAGMA table_info(adele_execution_$table)')
              .map((row) => row['name'] as String)
              .where((name) => name.endsWith('_json')),
          jsonColumns[table],
        );
      }
      expect(
        inspection
            .select('PRAGMA table_info(adele_execution_tool_invocations)')
            .map((row) => row['name']),
        [
          'run_id',
          'invocation_id',
          'prepared_sequence',
          'model_invocation_id',
          'proposal_sequence',
          'tool_id',
          'alias',
          'provider_call_id',
          'canonical_arguments_json',
        ],
      );
      expect(load(), isEmpty);
      expect(() => load().add(activity), throwsUnsupportedError);
    },
  );

  test('field-by-field roundtrip retains public evidence only across reopen', () {
    database.insertTerminalRun(record, activity);
    expect(inspection.select('PRAGMA foreign_key_check'), isEmpty);
    expect(
      inspection
          .select('SELECT DISTINCT kind FROM adele_execution_model_outputs')
          .map((row) => row['kind']),
      unorderedEquals(['text', 'toolProposal', 'native']),
    );
    for (final table in _tables) {
      expect(
        inspection.select('SELECT * FROM adele_execution_$table'),
        isNotEmpty,
      );
    }
    // Native data and safe presentation are distinct retained subfields.
    final nativeRow = inspection
        .select(
          "SELECT * FROM adele_execution_model_outputs WHERE kind = 'native'",
        )
        .single;
    expect(nativeRow['native_metadata_kind'], 'test.native');
    expect(
      jsonDecode(nativeRow['native_metadata_compatibility_json'] as String),
      {'protocol': 3},
    );
    expect(jsonDecode(nativeRow['native_metadata_data_json'] as String), {
      'opaque': ['retained', null, 1.5],
    });
    expect(nativeRow['presentation_kind'], 'test.safe');
    expect(nativeRow['presentation_compact_text'], 'Safe summary');
    expect(jsonDecode(nativeRow['presentation_data_json'] as String), {
      'summary': ['safe'],
    });
    final root = inspection
        .select('SELECT * FROM adele_execution_run_activity')
        .single;
    expect(root['failure_kind'], 'transport');
    expect(root['failure_message'], 'Connection lost');
    expect(root['failure_provider_code'], 'lost');
    expect(
      jsonDecode(root['failure_provider_details_json'] as String),
      activity.failure!.providerDetails,
    );
    final modelRow = inspection
        .select(
          "SELECT * FROM adele_execution_model_invocations WHERE invocation_id = 'model'",
        )
        .single;
    expect(
      [
        modelRow['metadata_present'],
        modelRow['effective_model'],
        modelRow['provider_response_id'],
        modelRow['provider_request_id'],
        modelRow['provider_stop_reason'],
        modelRow['usage_present'],
        modelRow['input_tokens'],
        modelRow['output_tokens'],
        modelRow['cache_read_tokens'],
        modelRow['cache_write_tokens'],
      ],
      [1, 'test-model', 'response', 'request', 'stop', 1, 200, 30, 40, 0],
    );
    expect(modelRow['native_state_kind'], 'test.native');
    expect(jsonDecode(modelRow['native_state_compatibility_json'] as String), {
      'protocol': 3,
    });
    expect(
      jsonDecode(modelRow['native_state_data_json'] as String),
      activity.models.first.metadata!.providerNativeState!.data,
    );
    final outcomeRow = inspection
        .select(
          'SELECT * FROM adele_execution_tool_changes WHERE sequence = 42',
        )
        .single;
    expect(
      [
        outcomeRow['outcome_disposition'],
        outcomeRow['failure_kind'],
        outcomeRow['effect_certainty'],
        outcomeRow['model_content'],
      ],
      ['success', null, 'knownOccurred', 'Outcome 0'],
    );
    expect(
      jsonDecode(outcomeRow['host_data_json'] as String),
      activity.tools.first.outcome!.hostData,
    );
    expect(
      inspection
          .select('SELECT settlement FROM adele_execution_model_invocations')
          .map((row) => row['settlement']),
      ['completed', 'incomplete', 'refused', null],
    );
    database.close();
    database = ProjectDatabase.open(backing);
    final history = load();
    _expectActivity(history.single, activity);
    expect(() => history.clear(), throwsUnsupportedError);
    expect(() => history.single.models.clear(), throwsUnsupportedError);
    expect(
      () => history.single.tools.first.changes.clear(),
      throwsUnsupportedError,
    );
    expect(
      () => history.single.tools.first.canonicalArguments['new'] = true,
      throwsUnsupportedError,
    );
    final nested =
        history.single.models.last.failure!.providerDetails['nested']
            as List<Object?>;
    expect(() => nested.add('new'), throwsUnsupportedError);
    expect(
      () =>
          history.single.models.first.metadata!.usage!.providerDetails['new'] =
              true,
      throwsUnsupportedError,
    );
    expect(
      () =>
          (history.single.models.first.outputs[1].item as ModelNativeOutput)
                  .presentation!
                  .data['new'] =
              true,
      throwsUnsupportedError,
    );
  });

  for (final state in RunTerminalState.values) {
    test(
      'minimal ${state.name} history uses product-authoritative state and Session',
      () {
        final terminal = RunRecord(
          id: record.id,
          sessionId: record.sessionId,
          state: state,
        );
        final snapshot = RunActivitySnapshot(
          runId: terminal.id,
          sessionId: terminal.sessionId,
          state: RunState.values.byName(state.name),
          sequence: 0,
          failure: state == RunTerminalState.failed
              ? ActivityFailure(kind: 'unknown', message: 'Run failed.')
              : null,
          lifecycle: [
            RunLifecycleActivity(
              sequence: 0,
              state: RunState.values.byName(state.name),
            ),
          ],
        );
        database.insertTerminalRun(terminal, snapshot);
        _expectActivity(load().single, snapshot);
      },
    );
  }

  test('invocation identities and sequence numbers are scoped to each Run', () {
    database.insertTerminalRun(record, activity);
    final second = RunRecord(
      id: RunId('second'),
      sessionId: record.sessionId,
      state: record.state,
    );
    final secondActivity = _fixture(second);
    database.insertTerminalRun(second, secondActivity);
    final history = load();
    expect(history, hasLength(2));
    _expectActivity(
      history.singleWhere((value) => value.runId == second.id),
      secondActivity,
    );
  });

  for (final commitFailure in [false, true]) {
    test(
      '${commitFailure ? 'COMMIT' : 'late evidence INSERT'} failure rolls back record and all seven tables',
      () {
        inspection.execute(
          commitFailure
              ? '''
        CREATE TABLE deferred_check (run_id TEXT REFERENCES adele_product_runs(id) DEFERRABLE INITIALLY DEFERRED);
        CREATE TRIGGER fail_evidence AFTER INSERT ON adele_execution_rejected_proposals
        BEGIN INSERT INTO deferred_check VALUES ('missing'); END;
      '''
              : '''
        CREATE TRIGGER fail_evidence BEFORE INSERT ON adele_execution_rejected_proposals
        BEGIN SELECT RAISE(ABORT, 'evidence failure'); END;
      ''',
        );
        expect(
          () => database.insertTerminalRun(record, activity),
          throwsA(isA<SqliteException>()),
        );
        expect(database.autocommit, isTrue);
        expect(inspection.select('SELECT * FROM adele_product_runs'), isEmpty);
        for (final table in _tables) {
          expect(
            inspection.select('SELECT * FROM adele_execution_$table'),
            isEmpty,
            reason: table,
          );
        }
        if (commitFailure) {
          expect(inspection.select('SELECT * FROM deferred_check'), isEmpty);
        }
        inspection.execute('DROP TRIGGER fail_evidence');
        database.insertTerminalRun(record, activity);
        _expectActivity(load().single, activity);
      },
    );
  }

  test('duplicate insert never replaces an existing record or evidence', () {
    database.insertTerminalRun(record, activity);
    expect(
      () => database.insertTerminalRun(record, activity),
      throwsA(isA<SqliteException>()),
    );
    _expectActivity(load().single, activity);
  });

  test('terminal evidence does not invent missing subordinate settlement', () {
    final tool = activity.tools.first;
    final partialTool = ToolInvocationActivity(
      id: tool.id,
      preparedSequence: tool.preparedSequence,
      modelInvocationId: tool.modelInvocationId,
      proposalSequence: tool.proposalSequence,
      toolId: tool.toolId,
      alias: tool.alias,
      providerCallId: tool.providerCallId,
      canonicalArguments: tool.canonicalArguments,
      changes: tool.changes.take(1),
    );
    final partial = _copy(
      activity,
      tools: [partialTool],
      models: [
        activity.models.first,
        ModelInvocationActivity(
          id: ModelInvocationId('unfinished'),
          startSequence: 120,
          outputs: [
            ModelOutputActivity(
              sequence: 122,
              item: ModelNativeOutput(
                providerNativeMetadata: ModelNativeEnvelope(
                  kind: 'opaque',
                  compatibility: {},
                  data: {},
                ),
              ),
            ),
          ],
        ),
      ],
    );
    database.insertTerminalRun(record, partial);
    _expectActivity(load().single, partial);
  });

  test('equivalent effect sets and structured maps are order independent', () {
    final tool = activity.tools.first;
    final equivalent = ToolInvocationActivity(
      id: tool.id,
      preparedSequence: tool.preparedSequence,
      modelInvocationId: tool.modelInvocationId,
      proposalSequence: tool.proposalSequence,
      toolId: tool.toolId,
      alias: tool.alias,
      providerCallId: tool.providerCallId,
      canonicalArguments: tool.canonicalArguments,
      changes: tool.changes,
      effects: EffectDescription(
        effects: tool.effects!.effects.toList().reversed,
        targets: tool.effects!.targets,
        summary: tool.effects!.summary,
        uncertainty: tool.effects!.uncertainty,
      ),
      outcome: ToolOutcomeActivity(
        disposition: tool.outcome!.disposition,
        effectCertainty: tool.outcome!.effectCertainty,
        modelContent: tool.outcome!.modelContent,
        hostData: Map.fromEntries(
          tool.outcome!.hostData.entries.toList().reversed,
        ),
      ),
    );
    final snapshot = _copy(
      activity,
      tools: [equivalent, ...activity.tools.skip(1)],
    );
    database.insertTerminalRun(record, snapshot);
    _expectActivity(load().single, snapshot);
  });

  test('tool aggregates must match changes before storage derives them', () {
    final tool = activity.tools.first;
    for (final omitEffects in [true, false]) {
      final inconsistent = ToolInvocationActivity(
        id: tool.id,
        preparedSequence: tool.preparedSequence,
        modelInvocationId: tool.modelInvocationId,
        proposalSequence: tool.proposalSequence,
        toolId: tool.toolId,
        alias: tool.alias,
        providerCallId: tool.providerCallId,
        canonicalArguments: tool.canonicalArguments,
        changes: tool.changes,
        effects: omitEffects ? null : tool.effects,
        outcome: omitEffects ? tool.outcome : null,
      );
      final snapshot = _copy(
        activity,
        tools: [inconsistent, ...activity.tools.skip(1)],
      );
      expect(
        () => validateTerminalRunActivity(record, snapshot),
        throwsFormatException,
      );
      expect(
        () => database.insertTerminalRun(record, snapshot),
        throwsFormatException,
      );
      expect(load(), isEmpty);
    }
  });

  test(
    'failed model metadata is optional and empty metadata/usage remain distinct',
    () {
      final failed = activity.models.last;
      final snapshot = _copy(
        activity,
        models: [
          ...activity.models.take(3),
          ModelInvocationActivity(
            id: failed.id,
            startSequence: failed.startSequence,
            terminalSequence: failed.terminalSequence,
            failure: failed.failure,
          ),
        ],
      );
      database.insertTerminalRun(record, snapshot);
      expect(
        inspection.select(
          'SELECT invocation_id, metadata_present, usage_present '
          'FROM adele_execution_model_invocations ORDER BY start_sequence',
        ),
        [
          {'invocation_id': 'model', 'metadata_present': 1, 'usage_present': 1},
          {
            'invocation_id': 'incomplete',
            'metadata_present': 1,
            'usage_present': 1,
          },
          {
            'invocation_id': 'refused',
            'metadata_present': 1,
            'usage_present': 0,
          },
          {
            'invocation_id': 'failed',
            'metadata_present': 0,
            'usage_present': 0,
          },
        ],
      );
      _expectActivity(load().single, snapshot);
    },
  );

  test('a record without evidence is corruption, never an empty fallback', () {
    inspection.execute('INSERT INTO adele_product_runs VALUES (?, ?, ?)', [
      record.id.value,
      record.sessionId.value,
      record.state.name,
    ]);
    expect(database.loadProductGraph().runRecords, hasLength(1));
    expect(load, throwsFormatException);
    expect(
      inspection.select('SELECT * FROM adele_execution_run_activity'),
      isEmpty,
    );
  });

  test(
    'execution initialization failure rolls back its entire baseline and owner version',
    () {
      final conflictBacking = ProjectBacking(
        sourceLocation: backing.sourceLocation,
        databaseRelativePath: 'conflict.sqlite',
      );
      final conflict = sqlite3.open(
        File.fromUri(backing.sourceLocation.resolve('conflict.sqlite')).path,
      );
      addTearDown(conflict.close);
      conflict.execute(
        'CREATE TABLE adele_execution_model_outputs (untouched TEXT)',
      );
      conflict.execute(
        "INSERT INTO adele_execution_model_outputs VALUES ('preserved')",
      );
      expect(
        () => ProjectDatabase.open(conflictBacking),
        throwsA(isA<SqliteException>()),
      );
      expect(
        conflict
            .select(
              "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'adele_execution_%'",
            )
            .map((row) => row['name']),
        ['adele_execution_model_outputs'],
      );
      expect(conflict.select('SELECT * FROM adele_schema_versions'), [
        {'owner_id': 'dev.adele.product', 'version': 1},
      ]);
      expect(
        conflict
            .select('SELECT untouched FROM adele_execution_model_outputs')
            .single['untouched'],
        'preserved',
      );
    },
  );

  test(
    'validation rejects mismatched identities, terminal states, ordering, and bounds before SQL',
    () {
      final invalid = [
        _copy(activity, omitFailure: true),
        _copy(activity, runId: RunId('other')),
        _copy(activity, sessionId: SessionId('other')),
        _copy(activity, state: RunState.completed),
        _copy(activity, state: RunState.running),
        _copy(activity, sequence: -1),
        _copy(activity, sequence: activity.sequence + 1),
        _copy(activity, lifecycle: []),
        _copy(activity, lifecycle: activity.lifecycle.reversed),
        _copy(activity, models: activity.models.reversed),
        _copy(activity, models: [...activity.models, activity.models.first]),
        _copy(
          activity,
          models: [
            ModelInvocationActivity(
              id: activity.models.first.id,
              startSequence: 2,
              terminalSequence: 24,
              settlement: ModelSettlement.completed,
            ),
          ],
        ),
        _copy(activity, tools: activity.tools.reversed),
        _copy(
          activity,
          rejectedProposals: [
            ...activity.rejectedProposals,
            activity.rejectedProposals.first,
          ],
        ),
      ];
      for (final value in invalid) {
        expect(
          () => validateTerminalRunActivity(record, value),
          throwsFormatException,
        );
        expect(
          () => database.insertTerminalRun(record, value),
          throwsFormatException,
        );
        expect(database.autocommit, isTrue);
        expect(inspection.select('SELECT * FROM adele_product_runs'), isEmpty);
        expect(load(), isEmpty);
      }
    },
  );

  test('load requires the complete, unique, matching terminal record set', () {
    database.insertTerminalRun(record, activity);
    final wrongSession = RunRecord(
      id: record.id,
      sessionId: SessionId('other'),
      state: record.state,
    );
    final wrongState = RunRecord(
      id: record.id,
      sessionId: record.sessionId,
      state: RunTerminalState.completed,
    );
    for (final records in <List<RunRecord>>[
      [],
      [record, record],
      [wrongSession],
      [wrongState],
    ]) {
      expect(
        () => database.loadExecutionHistory(records),
        throwsFormatException,
      );
      expect(database.autocommit, isTrue);
    }
  });

  for (final sql in [
    'DELETE FROM adele_execution_run_activity',
    "UPDATE adele_execution_run_activity SET run_id = 'orphan'",
    "UPDATE adele_execution_run_lifecycle SET run_id = 'orphan' WHERE sequence = 0",
    "UPDATE adele_execution_model_invocations SET run_id = 'orphan' WHERE invocation_id = 'model'",
    "UPDATE adele_execution_model_outputs SET model_invocation_id = 'missing' WHERE sequence = 4",
    "UPDATE adele_execution_tool_changes SET tool_invocation_id = 'missing' WHERE sequence = 30",
    "UPDATE adele_execution_tool_invocations SET run_id = 'orphan' WHERE invocation_id = 'tool-0'",
    "UPDATE adele_execution_rejected_proposals SET run_id = 'orphan'",
    'DELETE FROM adele_execution_run_lifecycle',
    'UPDATE adele_execution_run_activity SET latest_sequence = -1',
    'UPDATE adele_execution_run_activity SET latest_sequence = 151',
    "UPDATE adele_execution_run_lifecycle SET state = 'running' WHERE sequence = 150",
    "UPDATE adele_execution_run_lifecycle SET state = 'failed' WHERE sequence = 0",
    "UPDATE adele_execution_run_lifecycle SET state = 'invented' WHERE sequence = 0",
    "UPDATE adele_execution_model_invocations SET start_sequence = 0 WHERE invocation_id = 'model'",
    "UPDATE adele_execution_model_invocations SET terminal_sequence = 3 WHERE invocation_id = 'model'",
    "UPDATE adele_execution_model_invocations SET settlement = 'invalid' WHERE invocation_id = 'model'",
    "UPDATE adele_execution_model_invocations SET incomplete_reason = NULL WHERE settlement = 'incomplete'",
    "UPDATE adele_execution_model_invocations SET incomplete_reason = 'other' WHERE invocation_id = 'model'",
    "UPDATE adele_execution_model_invocations SET terminal_sequence = NULL WHERE invocation_id = 'model'",
    "UPDATE adele_execution_model_invocations SET invocation_id = ' invalid' WHERE invocation_id = 'refused'",
    "UPDATE adele_execution_model_outputs SET sequence = -1 WHERE sequence = 4",
    "UPDATE adele_execution_model_outputs SET kind = 'unknown' WHERE sequence = 4",
    "UPDATE adele_execution_model_outputs SET presentation_data_json = '{}' WHERE sequence = 4",
    "UPDATE adele_execution_model_outputs SET native_metadata_kind = NULL WHERE kind = 'native'",
    "UPDATE adele_execution_model_outputs SET native_metadata_kind = NULL, native_metadata_compatibility_json = NULL, native_metadata_data_json = NULL WHERE kind = 'native'",
    "UPDATE adele_execution_model_outputs SET alias = 'unexpected' WHERE sequence = 4",
    "UPDATE adele_execution_model_outputs SET arguments_json = '[]' WHERE kind = 'toolProposal'",
    "UPDATE adele_execution_model_outputs SET kind = 'proposal' WHERE kind = 'toolProposal'",
    "UPDATE adele_execution_model_outputs SET native_metadata_data_json = 'null' WHERE kind = 'native'",
    "UPDATE adele_execution_model_outputs SET native_metadata_data_json = '{broken' WHERE kind = 'native'",
    "UPDATE adele_execution_model_outputs SET native_metadata_compatibility_json = '[]' WHERE kind = 'native'",
    "UPDATE adele_execution_model_outputs SET native_metadata_compatibility_json = NULL WHERE kind = 'native'",
    "UPDATE adele_execution_model_outputs SET presentation_compact_text = NULL WHERE kind = 'native'",
    "UPDATE adele_execution_model_outputs SET presentation_compact_text = '' WHERE kind = 'native'",
    "UPDATE adele_execution_model_outputs SET presentation_data_json = '[]' WHERE kind = 'native'",
    "UPDATE adele_execution_model_outputs SET presentation_kind = NULL WHERE kind = 'native'",
    "UPDATE adele_execution_model_invocations SET metadata_present = 2 WHERE invocation_id = 'model'",
    "UPDATE adele_execution_model_invocations SET metadata_present = 0 WHERE invocation_id = 'model'",
    "UPDATE adele_execution_model_invocations SET metadata_present = 0 WHERE invocation_id = 'refused'",
    "UPDATE adele_execution_model_invocations SET usage_present = 2 WHERE invocation_id = 'model'",
    "UPDATE adele_execution_model_invocations SET usage_present = 0 WHERE invocation_id = 'model'",
    "UPDATE adele_execution_model_invocations SET usage_present = 1 WHERE invocation_id = 'refused'",
    "UPDATE adele_execution_model_invocations SET input_tokens = 1.5 WHERE invocation_id = 'model'",
    "UPDATE adele_execution_model_invocations SET input_tokens = -1 WHERE invocation_id = 'model'",
    "UPDATE adele_execution_model_invocations SET input_tokens = 'bad' WHERE invocation_id = 'model'",
    "UPDATE adele_execution_model_invocations SET usage_provider_details_json = '[]' WHERE invocation_id = 'model'",
    "UPDATE adele_execution_model_invocations SET usage_provider_details_json = NULL WHERE invocation_id = 'model'",
    "UPDATE adele_execution_model_invocations SET effective_model = '' WHERE invocation_id = 'model'",
    "UPDATE adele_execution_model_invocations SET native_state_kind = NULL WHERE invocation_id = 'model'",
    "UPDATE adele_execution_model_invocations SET native_state_data_json = '[]' WHERE invocation_id = 'model'",
    "UPDATE adele_execution_model_invocations SET native_state_compatibility_json = NULL WHERE invocation_id = 'model'",
    "UPDATE adele_execution_run_activity SET failure_kind = NULL",
    "UPDATE adele_execution_run_activity SET failure_kind = NULL, failure_message = NULL, failure_provider_code = NULL, failure_provider_details_json = NULL",
    "UPDATE adele_execution_run_activity SET failure_message = ''",
    "UPDATE adele_execution_run_activity SET failure_provider_details_json = '[]'",
    "UPDATE adele_execution_run_activity SET failure_provider_details_json = NULL",
    "UPDATE adele_execution_model_invocations SET failure_message = NULL WHERE invocation_id = 'failed'",
    "UPDATE adele_execution_model_invocations SET failure_kind = NULL WHERE invocation_id = 'failed'",
    "UPDATE adele_execution_model_invocations SET failure_provider_code = '' WHERE invocation_id = 'failed'",
    "UPDATE adele_execution_tool_invocations SET proposal_sequence = 4 WHERE invocation_id = 'tool-0'",
    "UPDATE adele_execution_tool_invocations SET model_invocation_id = 'refused' WHERE invocation_id = 'tool-0'",
    "UPDATE adele_execution_tool_invocations SET provider_call_id = 'wrong' WHERE invocation_id = 'tool-0'",
    "UPDATE adele_execution_tool_invocations SET prepared_sequence = -1 WHERE invocation_id = 'tool-0'",
    "UPDATE adele_execution_tool_invocations SET canonical_arguments_json = 'false' WHERE invocation_id = 'tool-0'",
    "DELETE FROM adele_execution_tool_changes WHERE sequence = 30",
    "UPDATE adele_execution_tool_changes SET kind = 'unknown' WHERE sequence = 30",
    "UPDATE adele_execution_tool_changes SET policy_decision = 'allow' WHERE sequence = 30",
    "UPDATE adele_execution_tool_changes SET effects_json = NULL WHERE sequence = 31",
    "UPDATE adele_execution_tool_changes SET policy_decision = 'unknown' WHERE sequence = 31",
    "UPDATE adele_execution_tool_changes SET effects_json = json_set(effects_json, '\$.effects', 'bad') WHERE sequence = 31",
    "UPDATE adele_execution_tool_changes SET effects_json = json_set(effects_json, '\$.targets', 'bad') WHERE sequence = 31",
    "UPDATE adele_execution_tool_changes SET effects_json = json_set(effects_json, '\$.uncertainty', 'unknown') WHERE sequence = 31",
    "UPDATE adele_execution_tool_changes SET approved = 2 WHERE sequence = 35",
    "UPDATE adele_execution_tool_changes SET interruption_id = 'wrong' WHERE sequence = 35",
    "UPDATE adele_execution_tool_changes SET progress_kind = NULL WHERE sequence = 38",
    "UPDATE adele_execution_tool_changes SET progress_kind = 'unknown' WHERE sequence = 38",
    "UPDATE adele_execution_tool_changes SET progress_content = '' WHERE sequence = 38",
    "UPDATE adele_execution_tool_changes SET outcome_disposition = NULL WHERE sequence = 42",
    "UPDATE adele_execution_tool_changes SET outcome_disposition = 'unknown' WHERE sequence = 42",
    "UPDATE adele_execution_tool_changes SET failure_kind = 'domain' WHERE sequence = 42",
    "UPDATE adele_execution_tool_changes SET failure_kind = NULL WHERE sequence = 74",
    "UPDATE adele_execution_tool_changes SET effect_certainty = 'unknown' WHERE sequence = 42",
    "UPDATE adele_execution_tool_changes SET model_content = '' WHERE sequence = 42",
    "UPDATE adele_execution_tool_changes SET model_content = 'unexpected' WHERE sequence = 30",
    "UPDATE adele_execution_tool_changes SET host_data_json = '[]' WHERE sequence = 42",
    "UPDATE adele_execution_tool_changes SET host_data_json = NULL WHERE sequence = 42",
    "UPDATE adele_execution_rejected_proposals SET proposal_sequence = 10",
    "UPDATE adele_execution_rejected_proposals SET arguments_json = '{}'",
    "UPDATE adele_execution_rejected_proposals SET failure_kind = 'unknown'",
    "UPDATE adele_execution_rejected_proposals SET message = ''",
  ]) {
    test('corruption fails complete evidence load: $sql', () {
      database.insertTerminalRun(record, activity);
      inspection.execute('PRAGMA ignore_check_constraints = ON');
      inspection.execute(sql);
      // Product loading does not read, repair, or ignore execution corruption.
      expect(database.loadProductGraph().runRecords.single.id, record.id);
      expect(
        load,
        throwsA(anyOf(isA<FormatException>(), isA<ArgumentError>())),
      );
      expect(database.autocommit, isTrue);
    });
  }

  test('closed database rejects evidence reads', () {
    database.close();
    expect(() => database.loadExecutionHistory([]), throwsStateError);
  });

  for (final version in <Object>[2, -1, 'bad', 1.5]) {
    test('unsupported execution version $version fails non-destructively', () {
      database.insertTerminalRun(record, activity);
      final path = database.path;
      database.close();
      inspection.execute(
        "UPDATE adele_schema_versions SET version = ? WHERE owner_id = 'dev.adele.execution'",
        [version],
      );
      inspection.close();
      final before = File(path).readAsBytesSync();
      expect(
        () => ProjectDatabase.open(backing),
        throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
      );
      expect(File(path).readAsBytesSync(), before);
    });
  }
}

RunActivitySnapshot _fixture(RunRecord record) {
  final native = ModelNativeEnvelope(
    kind: 'test.native',
    compatibility: {'protocol': 3},
    data: {
      'opaque': ['retained', null, 1.5],
    },
  );
  final metadata = ModelTerminalMetadata(
    effectiveModel: 'test-model',
    providerResponseId: 'response',
    providerRequestId: 'request',
    providerStopReason: 'stop',
    providerNativeState: native,
    usage: ModelUsage(
      inputTokens: 200,
      outputTokens: 30,
      cacheReadTokens: 40,
      cacheWriteTokens: 0,
      providerDetails: {
        'billing': {'units': 1.5, 'cached': true},
      },
    ),
  );
  final failure = ActivityFailure(
    kind: 'transport',
    message: 'Connection lost',
    providerCode: 'lost',
    providerDetails: {
      'retryable': false,
      'nested': [
        null,
        12,
        {'safe': true},
      ],
    },
  );
  final model = ModelInvocationId('model');
  final proposals = [
    for (var i = 0; i < 8; i++)
      ProviderToolProposal(
        providerCallId: 'call-$i',
        alias: 'tool-$i',
        arguments: {
          'raw': i,
          'nested': [null, false, 'text'],
        },
      ),
  ];
  final effects = EffectDescription(
    effects: ToolEffect.values,
    targets: [
      EffectTarget(uri: Uri.parse('file:///source/a%20b')),
      EffectTarget(uri: Uri.parse('process:check')),
    ],
    summary: 'Inspect, mutate, and execute',
    uncertainty: EffectUncertainty.uncertain,
  );
  final dispositions = [
    ToolOutcomeDisposition.success,
    ToolOutcomeDisposition.policyDenied,
    ToolOutcomeDisposition.userRejected,
    ToolOutcomeDisposition.failure,
    ToolOutcomeDisposition.failure,
    ToolOutcomeDisposition.cancelled,
    ToolOutcomeDisposition.indeterminate,
  ];
  final tools = <ToolInvocationActivity>[];
  for (var i = 0; i < 7; i++) {
    final start = [30, 50, 60, 70, 80, 90, 100][i];
    final outcome = ToolOutcomeActivity(
      disposition: dispositions[i],
      failureKind: i == 3
          ? ToolFailureKind.domain
          : i == 4
          ? ToolFailureKind.infrastructure
          : null,
      effectCertainty: i == 0
          ? EffectCertainty.knownOccurred
          : i < 4
          ? EffectCertainty.knownNotOccurred
          : EffectCertainty.uncertain,
      modelContent: 'Outcome $i',
      hostData: {
        'exit': i,
        'nested': {'ok': i == 0},
        'items': [null, 1.25],
      },
    );
    final interruption = RunInterruptionId('approval-$i');
    final changes = <ToolActivityChange>[
      ToolActivityChange(sequence: start, kind: ToolActivityKind.prepared),
      ToolActivityChange(
        sequence: start + 1,
        kind: i == 3
            ? ToolActivityKind.policyFailed
            : ToolActivityKind.policyEvaluated,
        effects: effects,
        policyDecision: i == 3
            ? null
            : i == 1
            ? ToolActivityPolicyDecision.deny
            : i == 0 || i == 2
            ? ToolActivityPolicyDecision.ask
            : ToolActivityPolicyDecision.allow,
      ),
      if (i == 0 || i == 2) ...[
        ToolActivityChange(
          sequence: start + 2,
          kind: ToolActivityKind.approvalRequested,
          effects: effects,
          interruptionId: interruption,
        ),
        ToolActivityChange(
          sequence: start + 5,
          kind: ToolActivityKind.approvalResolved,
          interruptionId: interruption,
          approved: i == 0,
        ),
      ],
      if (i == 0 || i >= 4)
        ToolActivityChange(
          sequence: start + (i == 0 ? 7 : 2),
          kind: ToolActivityKind.executionStarted,
        ),
      if (i == 0)
        for (final kind in ToolProgressKind.values)
          ToolActivityChange(
            sequence: 38 + kind.index,
            kind: ToolActivityKind.progress,
            progress: ToolProgress(
              kind: kind,
              content: '${kind.name} content\n',
            ),
          ),
      ToolActivityChange(
        sequence:
            start +
            (i == 0
                ? 12
                : i == 2
                ? 7
                : i == 1
                ? 2
                : 4),
        kind: ToolActivityKind.completed,
        outcome: outcome,
      ),
    ];
    tools.add(
      ToolInvocationActivity(
        id: ToolInvocationId('tool-$i'),
        preparedSequence: start,
        modelInvocationId: model,
        proposalSequence: 10 + i,
        toolId: ToolId('test.tool.$i'),
        alias: proposals[i].alias,
        providerCallId: proposals[i].providerCallId,
        canonicalArguments: {
          'normalized': i,
          'map': {
            'list': [true, null, 1.5],
          },
        },
        changes: changes,
        effects: effects,
        outcome: outcome,
      ),
    );
  }
  return RunActivitySnapshot(
    runId: record.id,
    sessionId: record.sessionId,
    state: RunState.failed,
    sequence: 150,
    failure: failure,
    lifecycle: const [
      RunLifecycleActivity(sequence: 0, state: RunState.running),
      RunLifecycleActivity(sequence: 33, state: RunState.waiting),
      RunLifecycleActivity(sequence: 36, state: RunState.running),
      RunLifecycleActivity(sequence: 63, state: RunState.waiting),
      RunLifecycleActivity(sequence: 66, state: RunState.running),
      RunLifecycleActivity(sequence: 150, state: RunState.failed),
    ],
    models: [
      ModelInvocationActivity(
        id: model,
        startSequence: 2,
        terminalSequence: 24,
        settlement: ModelSettlement.completed,
        metadata: metadata,
        outputs: [
          ModelOutputActivity(
            sequence: 4,
            item: ModelTextOutput(
              'Completed text',
              providerItemId: 'text-item',
              providerNativeMetadata: native,
            ),
          ),
          ModelOutputActivity(
            sequence: 6,
            item: ModelNativeOutput(
              providerNativeMetadata: native,
              providerItemId: 'native-item',
              presentation: ModelNativePresentation(
                kind: 'test.safe',
                compactText: 'Safe summary',
                data: {
                  'summary': ['safe'],
                },
              ),
            ),
          ),
          for (var i = 0; i < proposals.length; i++)
            ModelOutputActivity(
              sequence: 10 + i,
              item: ModelToolProposalOutput(
                proposals[i],
                providerItemId: 'proposal-$i',
                providerNativeMetadata: i == 0 ? native : null,
              ),
            ),
        ],
      ),
      ModelInvocationActivity(
        id: ModelInvocationId('incomplete'),
        startSequence: 120,
        terminalSequence: 124,
        settlement: ModelSettlement.incomplete,
        incompleteReason: ModelIncompleteReason.outputLimit,
        metadata: ModelTerminalMetadata(usage: ModelUsage()),
        outputs: [
          ModelOutputActivity(sequence: 122, item: ModelTextOutput('Partial')),
        ],
      ),
      ModelInvocationActivity(
        id: ModelInvocationId('refused'),
        startSequence: 130,
        terminalSequence: 132,
        settlement: ModelSettlement.refused,
        metadata: ModelTerminalMetadata(),
      ),
      ModelInvocationActivity(
        id: ModelInvocationId('failed'),
        startSequence: 140,
        terminalSequence: 144,
        failure: failure,
        metadata: metadata,
      ),
    ],
    tools: tools,
    rejectedProposals: [
      RejectedToolProposalActivity(
        sequence: 110,
        modelInvocationId: model,
        proposalSequence: 17,
        proposal: proposals.last,
        kind: ToolProposalFailureKind.unknownAlias,
        message: 'Unavailable alias',
      ),
    ],
  );
}

RunActivitySnapshot _copy(
  RunActivitySnapshot value, {
  RunId? runId,
  SessionId? sessionId,
  RunState? state,
  int? sequence,
  Iterable<RunLifecycleActivity>? lifecycle,
  Iterable<ModelInvocationActivity>? models,
  Iterable<ToolInvocationActivity>? tools,
  Iterable<RejectedToolProposalActivity>? rejectedProposals,
  bool omitFailure = false,
}) => RunActivitySnapshot(
  runId: runId ?? value.runId,
  sessionId: sessionId ?? value.sessionId,
  state: state ?? value.state,
  sequence: sequence ?? value.sequence,
  lifecycle: lifecycle ?? value.lifecycle,
  models: models ?? value.models,
  tools: tools ?? value.tools,
  rejectedProposals: rejectedProposals ?? value.rejectedProposals,
  failure: omitFailure ? null : value.failure,
);

void _expectActivity(RunActivitySnapshot actual, RunActivitySnapshot expected) {
  expect(actual.runId, expected.runId);
  expect(actual.sessionId, expected.sessionId);
  expect(actual.state, expected.state);
  expect(actual.sequence, expected.sequence);
  _expectFailure(actual.failure, expected.failure);
  expect(
    actual.lifecycle.map((value) => (value.sequence, value.state)),
    expected.lifecycle.map((value) => (value.sequence, value.state)),
  );
  expect(actual.models.length, expected.models.length);
  for (var i = 0; i < expected.models.length; i++) {
    final a = actual.models[i];
    final e = expected.models[i];
    expect(a.id, e.id);
    expect(a.startSequence, e.startSequence);
    expect(a.terminalSequence, e.terminalSequence);
    expect(a.settlement, e.settlement);
    expect(a.incompleteReason, e.incompleteReason);
    _expectFailure(a.failure, e.failure);
    expect(a.metadata == null, e.metadata == null);
    expect(a.metadata?.effectiveModel, e.metadata?.effectiveModel);
    expect(a.metadata?.providerResponseId, e.metadata?.providerResponseId);
    expect(a.metadata?.providerRequestId, e.metadata?.providerRequestId);
    expect(a.metadata?.providerStopReason, e.metadata?.providerStopReason);
    _expectNative(
      a.metadata?.providerNativeState,
      e.metadata?.providerNativeState,
    );
    expect(a.metadata?.usage == null, e.metadata?.usage == null);
    expect(a.metadata?.usage?.inputTokens, e.metadata?.usage?.inputTokens);
    expect(a.metadata?.usage?.outputTokens, e.metadata?.usage?.outputTokens);
    expect(
      a.metadata?.usage?.cacheReadTokens,
      e.metadata?.usage?.cacheReadTokens,
    );
    expect(
      a.metadata?.usage?.cacheWriteTokens,
      e.metadata?.usage?.cacheWriteTokens,
    );
    expect(
      a.metadata?.usage?.providerDetails,
      e.metadata?.usage?.providerDetails,
    );
    expect(a.outputs.length, e.outputs.length);
    for (var j = 0; j < e.outputs.length; j++) {
      expect(a.outputs[j].sequence, e.outputs[j].sequence);
      final item = a.outputs[j].item;
      switch (e.outputs[j].item) {
        case ModelTextOutput(
          :final content,
          :final providerItemId,
          :final providerNativeMetadata,
        ):
          expect(item, isA<ModelTextOutput>());
          final text = item as ModelTextOutput;
          expect(text.content, content);
          expect(text.providerItemId, providerItemId);
          _expectNative(text.providerNativeMetadata, providerNativeMetadata);
        case ModelNativeOutput(
          :final providerItemId,
          :final providerNativeMetadata,
          :final presentation,
        ):
          expect(item, isA<ModelNativeOutput>());
          final native = item as ModelNativeOutput;
          expect(native.providerItemId, providerItemId);
          _expectNative(native.providerNativeMetadata, providerNativeMetadata);
          expect(native.presentation == null, presentation == null);
          expect(native.presentation?.kind, presentation?.kind);
          expect(native.presentation?.compactText, presentation?.compactText);
          expect(native.presentation?.data, presentation?.data);
        case ModelToolProposalOutput(
          :final proposal,
          :final providerItemId,
          :final providerNativeMetadata,
        ):
          expect(item, isA<ModelToolProposalOutput>());
          final output = item as ModelToolProposalOutput;
          expect(output.providerItemId, providerItemId);
          _expectNative(output.providerNativeMetadata, providerNativeMetadata);
          _expectProposal(output.proposal, proposal);
      }
    }
  }
  expect(actual.tools.length, expected.tools.length);
  for (var i = 0; i < expected.tools.length; i++) {
    final a = actual.tools[i];
    final e = expected.tools[i];
    expect(a.id, e.id);
    expect(a.preparedSequence, e.preparedSequence);
    expect(a.modelInvocationId, e.modelInvocationId);
    expect(a.proposalSequence, e.proposalSequence);
    expect(a.toolId, e.toolId);
    expect(a.alias, e.alias);
    expect(a.providerCallId, e.providerCallId);
    expect(a.canonicalArguments, e.canonicalArguments);
    _expectEffects(a.effects, e.effects);
    _expectOutcome(a.outcome, e.outcome);
    expect(a.changes.length, e.changes.length);
    for (var j = 0; j < e.changes.length; j++) {
      final ac = a.changes[j];
      final ec = e.changes[j];
      expect(ac.sequence, ec.sequence);
      expect(ac.kind, ec.kind);
      expect(ac.policyDecision, ec.policyDecision);
      expect(ac.interruptionId, ec.interruptionId);
      expect(ac.approved, ec.approved);
      expect(ac.progress == null, ec.progress == null);
      expect(ac.progress?.kind, ec.progress?.kind);
      expect(ac.progress?.content, ec.progress?.content);
      _expectEffects(ac.effects, ec.effects);
      _expectOutcome(ac.outcome, ec.outcome);
    }
  }
  expect(actual.rejectedProposals.length, expected.rejectedProposals.length);
  for (var i = 0; i < expected.rejectedProposals.length; i++) {
    final a = actual.rejectedProposals[i];
    final e = expected.rejectedProposals[i];
    expect(a.sequence, e.sequence);
    expect(a.modelInvocationId, e.modelInvocationId);
    expect(a.proposalSequence, e.proposalSequence);
    expect(a.kind, e.kind);
    expect(a.message, e.message);
    _expectProposal(a.proposal, e.proposal);
  }
}

void _expectFailure(ActivityFailure? a, ActivityFailure? e) {
  expect(a == null, e == null);
  expect(a?.kind, e?.kind);
  expect(a?.message, e?.message);
  expect(a?.providerCode, e?.providerCode);
  expect(a?.providerDetails, e?.providerDetails);
}

void _expectNative(ModelNativeEnvelope? a, ModelNativeEnvelope? e) {
  expect(a == null, e == null);
  expect(a?.kind, e?.kind);
  expect(a?.compatibility, e?.compatibility);
  expect(a?.data, e?.data);
}

void _expectProposal(ProviderToolProposal a, ProviderToolProposal e) {
  expect(a.providerCallId, e.providerCallId);
  expect(a.alias, e.alias);
  expect(a.arguments, e.arguments);
}

void _expectEffects(EffectDescription? a, EffectDescription? e) {
  expect(a == null, e == null);
  expect(a?.effects, e?.effects);
  expect(
    a?.targets.map((target) => target.uri),
    e?.targets.map((target) => target.uri),
  );
  expect(a?.summary, e?.summary);
  expect(a?.uncertainty, e?.uncertainty);
}

void _expectOutcome(ToolOutcomeActivity? a, ToolOutcomeActivity? e) {
  expect(a == null, e == null);
  expect(a?.disposition, e?.disposition);
  expect(a?.failureKind, e?.failureKind);
  expect(a?.effectCertainty, e?.effectCertainty);
  expect(a?.modelContent, e?.modelContent);
  expect(a?.hostData, e?.hostData);
}
