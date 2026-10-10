import 'dart:convert';

import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:session_evaluator_backend/session_evaluator_backend.dart';
import 'package:session_evaluator_backend/src/evidence_tables.dart';
import 'package:session_evaluator_contract/session_evaluator_contract.dart';
import 'package:test/test.dart';

const _session = 'session';
const _chatOwner = 'dev.adele.plugin.chat-strategy';
final _models = executionTables['model_invocations']!;
final _outputs = executionTables['model_outputs']!;
final _tools = executionTables['tool_invocations']!;
final _changes = executionTables['tool_changes']!;
final _rejections = executionTables['rejected_proposals']!;
typedef _Row = Map<String, Object?>;

void main() {
  late _QueryFixture storage;
  late SessionEvidenceCollector collector;

  setUp(() {
    storage = _QueryFixture();
    collector = SessionEvidenceCollector(storage);
    // Collector error translation must not hide failed fixture invariants.
    addTearDown(() => expect(storage.violations, isEmpty));
  });

  Future<Map<String, Object?>> read() =>
      readSessionEvidence(collector, _session);

  test('blank Session fails before acquiring storage', () async {
    await expectLater(
      readSessionEvidence(collector, ' \t'),
      throwsA(_failure('invalid_session')),
    );
    expect(storage.queries, isEmpty);
  });

  test('keyset pages retain every entry and Run-local identity', () async {
    storage.entries(4);
    for (final id in ['run-z', 'run-a']) {
      storage.addRun(id, latest: 5);
      storage.rows[_models.name]!.add(_model(id, 'same-model', 1, 3));
    }
    final document = await read();
    final conversation = document['conversation'] as _Row;
    expect(conversation['entries'], storage.rows[chatEntries.name]);
    expect(storage.cursors[chatEntries.name], [null, 0, 1, 2, 3]);
    expect(storage.cursors[productRuns.name], [null, 'run-a', 'run-z']);
    final runs = (document['runs'] as List).cast<_Row>();
    expect(runs.map((run) => run['id']), ['run-a', 'run-z']);
    for (final run in runs) {
      final model =
          ((run['evidence'] as _Row)['model_invocations'] as List).single
              as _Row;
      expect(model['invocation_id'], 'same-model');
      expect(model['run_id'], run['id']);
    }
    expect(
      (document['coverage'] as _Row)['run_order'],
      'lexical_id_not_chronology',
    );
  });

  for (final status in [
    'unavailable',
    'uninitialized',
    'available',
    'unsupported_strategy',
  ]) {
    test('empty conversation distinguishes $status', () async {
      switch (status) {
        case 'unavailable':
          storage.versions.remove(_chatOwner);
          storage.columns.remove(chatSessions.name);
          storage.columns.remove(chatEntries.name);
        case 'uninitialized':
          storage.rows[chatSessions.name]!.clear();
        case 'unsupported_strategy':
          storage.identity['strategy_id'] = 'test.other-strategy';
          storage.versions[_chatOwner] = ['not-a-version'];
        case 'available':
          break;
      }
      final document = await read();
      final conversation = document['conversation'] as _Row;
      expect(conversation['status'], status);
      expect(conversation['entries'], isEmpty);
      expect(
        conversation['configuration'],
        status == 'available' ? isA<_Row>() : isNull,
      );
      expect(
        (document['coverage'] as _Row)['status'],
        status == 'available' ? 'complete_retained_evidence' : 'partial',
      );
      if (status == 'unsupported_strategy') {
        expect(storage.queriedOwners, isNot(contains(_chatOwner)));
      }
    });
  }

  for (final corruption in <String, void Function(_QueryFixture)>{
    'missing execution table': (s) =>
        s.columns.remove(executionTables['root']!.name),
    'missing selected column': (s) =>
        s.columns[_models.name]!.remove('usage_present'),
    'partial Chat schema': (s) => s.columns.remove(chatEntries.name),
    'missing owner version': (s) => s.versions.remove('dev.adele.execution'),
    'unsupported version': (s) => s.versions[_chatOwner] = [2],
    'malformed version': (s) => s.versions[_chatOwner] = ['1'],
    'duplicate version': (s) => s.versions[_chatOwner] = [1, 1],
  }.entries) {
    test('${corruption.key} fails without publishing empty evidence', () async {
      corruption.value(storage);
      await _expectUnpublishedFailure(collector, 'incompatible_schema');
    });
  }

  for (final late in [false, true]) {
    test(
      '${late ? 'late' : 'initial'} query exception is never empty data',
      () async {
        storage.entries(2, content: 'already read ' * 2000);
        storage.failQuery = (sql, parameters) =>
            !late ||
            (sql.contains('from ${chatEntries.name} e') &&
                parameters[':after'] == 0);
        await _expectUnpublishedFailure(collector, 'storage_query_failed');
        await expectLater(read(), throwsA(_failure('storage_query_failed')));
        if (late) expect(storage.cursors[chatEntries.name], contains(null));
      },
    );
  }

  test(
    'assistant has no inferred Run, and unretained user association is partial',
    () async {
      storage.entries(3);
      storage.addRun('retained');
      storage.rows[chatEntries.name]![0]['run_id'] = 'retained';
      storage.rows[chatEntries.name]![2]['run_id'] = 'unretained';
      final document = await read();
      final entries = ((document['conversation'] as _Row)['entries'] as List)
          .cast<_Row>();
      expect(entries.map((entry) => entry['run_id']), [
        'retained',
        null,
        'unretained',
      ]);
      expect((document['coverage'] as _Row)['status'], 'partial');
      expect(
        (document['coverage']
            as _Row)['associated_runs_without_terminal_evidence'],
        ['unretained'],
      );
      expect((document['runs'] as List).single, containsPair('id', 'retained'));
    },
  );

  for (final association in ['assistant', 'foreign Run']) {
    test('$association association is rejected, not exported', () async {
      storage.entries(2);
      if (association == 'assistant') {
        storage.rows[chatEntries.name]![1]['run_id'] = 'run';
      } else {
        storage.rows[chatEntries.name]![0]['run_id'] = 'foreign';
        storage.rows[productRuns.name]!.add({
          'id': 'foreign',
          'session_id': 'another-session',
          'terminal_state': 'completed',
        });
      }
      await _expectUnpublishedFailure(collector, 'malformed_data');
    });
  }

  for (final corruption in [
    'hidden entry',
    'duplicate cursor',
    'orphan entries',
  ]) {
    test('Chat $corruption cannot silently publish a prefix', () async {
      storage.entries(1);
      switch (corruption) {
        case 'hidden entry':
          storage.rows[chatEntries.name]!.add(_chatEntry(2));
        case 'duplicate cursor':
          storage.rows[chatEntries.name]!.add(_chatEntry(0));
        case 'orphan entries':
          storage.rows[chatSessions.name]!.clear();
      }
      await _expectUnpublishedFailure(collector, 'malformed_data');
    });
  }

  test(
    'proposal provenance preserves execution, denial and rejection separately',
    () async {
      storage.detailedRun();
      final evidence = _evidence(await read());
      final outputs = (evidence['model_outputs'] as List).cast<_Row>();
      final tools = (evidence['tool_invocations'] as List).cast<_Row>();
      final changes = (evidence['tool_changes'] as List).cast<_Row>();
      expect(
        outputs.where((row) => row['kind'] == 'toolProposal'),
        hasLength(5),
      );
      expect(tools.map((row) => row['invocation_id']), [
        'executed',
        'denied',
        'user-rejected',
      ]);
      for (final tool in tools) {
        final proposal = outputs.singleWhere(
          (row) => row['sequence'] == tool['proposal_sequence'],
        );
        expect(tool['model_invocation_id'], proposal['model_invocation_id']);
        expect(tool['provider_call_id'], proposal['provider_call_id']);
        expect(tool['alias'], proposal['alias']);
        expect(proposal['arguments_json'], '{ "path": "source" }');
        expect(
          tool['canonical_arguments_json'],
          '{"path":"source","default":true}',
        );
      }
      expect(
        changes
            .where((row) => row['kind'] == 'executionStarted')
            .map((row) => row['tool_invocation_id']),
        ['executed'],
      );
      expect(
        changes
            .where((row) => row['kind'] == 'completed')
            .map(
              (row) => (row['outcome_disposition'], row['effect_certainty']),
            ),
        [
          ('success', 'knownOccurred'),
          ('policyDenied', 'knownNotOccurred'),
          ('userRejected', 'knownNotOccurred'),
        ],
      );
      final rejected = (evidence['rejected_proposals'] as List).single as _Row;
      expect(rejected['proposal_sequence'], 7);
      expect(rejected['failure_kind'], 'unknownAlias');
      expect(tools.any((row) => row['proposal_sequence'] == 7), isFalse);
      expect(tools.any((row) => row['proposal_sequence'] == 9), isFalse);
    },
  );

  test(
    'metadata and usage presence retain null counts separately from zero',
    () async {
      storage.addRun('run', latest: 10);
      storage.rows[_models.name]!.addAll([
        _model('run', 'absent-metadata', 1, 2, {
          'settlement': null,
          'metadata_present': 0,
          'failure_kind': 'transport',
          'failure_message': 'No response.',
          'failure_provider_details_json': '{}',
        }),
        _model('run', 'absent-usage', 3, 4),
        _model('run', 'empty-usage', 5, 6, {
          'usage_present': 1,
          'usage_provider_details_json': '{}',
        }),
        _model('run', 'known-zero', 7, 8, {
          'usage_present': 1,
          'usage_provider_details_json': '{ "unit": "tokens" }',
          'output_tokens': 0,
          'cache_write_tokens': 0,
        }),
      ]);
      final models = (_evidence(await read())['model_invocations'] as List)
          .cast<_Row>();
      expect(models, storage.rows[_models.name]);
      expect(models.map((m) => (m['metadata_present'], m['usage_present'])), [
        (0, 0),
        (1, 0),
        (1, 1),
        (1, 1),
      ]);
      expect(models.map((m) => m['input_tokens']), [null, null, null, null]);
      expect(models.map((m) => m['output_tokens']), [null, null, null, 0]);
      expect(
        models.last['usage_provider_details_json'],
        '{ "unit": "tokens" }',
      );
    },
  );

  test(
    'opaque provider state and draft are excluded, safe presentation is exact',
    () async {
      storage.detailedRun();
      storage.rows[chatSessions.name]!.single['draft_request'] = 'SECRET-DRAFT';
      storage.rows[_models.name]!.single.addAll({
        'native_state_kind': 'provider.state',
        'native_state_compatibility_json': 'SECRET-COMPATIBILITY',
        'native_state_data_json': 'SECRET-OPAQUE-STATE',
      });
      final native = storage.rows[_outputs.name]!.singleWhere(
        (row) => row['kind'] == 'native',
      );
      native.addAll({
        'native_metadata_compatibility_json': 'SECRET-NATIVE-COMPATIBILITY',
        'native_metadata_data_json': 'SECRET-NATIVE-DATA',
      });
      final document = await read();
      expect(jsonEncode(document), isNot(contains('SECRET-')));
      final evidence = _evidence(document);
      final exported = (evidence['model_outputs'] as List)
          .cast<_Row>()
          .singleWhere((row) => row['kind'] == 'native');
      expect(exported['presentation_kind'], 'provider.safe');
      expect(exported['presentation_compact_text'], 'Safe summary');
      expect(exported['presentation_data_json'], '{ "summary": ["safe"] }');
      expect(exported['native_metadata_kind'], 'provider.note');
      expect(exported, isNot(contains('native_metadata_data_json')));
      expect(
        (evidence['model_invocations'] as List).single,
        isNot(contains('native_state_data_json')),
      );
      expect(
        (document['conversation'] as _Row)['configuration'],
        isNot(contains('draft_request')),
      );
    },
  );

  for (final state in ['failed', 'cancelled']) {
    test('$state Run retains failure and unfinished model facts', () async {
      storage.addRun('run', latest: 4);
      storage.rows[productRuns.name]!.single['terminal_state'] = state;
      storage.rows[executionTables['lifecycle']!.name]!.last['state'] = state;
      if (state == 'failed') {
        storage.rows[executionTables['root']!.name]!.single.addAll({
          'failure_kind': 'FixtureFailure',
          'failure_message': 'Exact retained failure.',
          'failure_provider_code': 'fixture-code',
          'failure_provider_details_json': '{ "retained": true }',
        });
      }
      storage.rows[_models.name]!.add(
        _model('run', 'unfinished', 1, 2, {
          'terminal_sequence': null,
          'settlement': null,
          'metadata_present': 0,
        }),
      );
      final document = await read();
      final run = (document['runs'] as List).single as _Row;
      expect(run['terminal_state'], state);
      expect(
        _evidence(document)['root'],
        storage.rows[executionTables['root']!.name]!.single,
      );
      final model =
          (_evidence(document)['model_invocations'] as List).single as _Row;
      expect(model['terminal_sequence'], isNull);
      expect(model['settlement'], isNull);
      expect(model['metadata_present'], 0);
    });
  }

  for (final corruption in <String, void Function(_QueryFixture)>{
    'malformed JSON': (s) =>
        s.rows[_tools.name]!.first['canonical_arguments_json'] = '{bad',
    'non-object JSON': (s) =>
        s.rows[_outputs.name]![2]['arguments_json'] = '[]',
    'nonfinite JSON number': (s) =>
        s.rows[_tools.name]!.first['canonical_arguments_json'] =
            '{"value":1e999}',
    'overdeep JSON': (s) =>
        s.rows[_tools.name]!.first['canonical_arguments_json'] =
            '{"value":${'[' * 65}0${']' * 65}}',
    'string token count': (s) =>
        s.rows[_models.name]!.single['input_tokens'] = '0',
    'contradictory usage flag': (s) =>
        s.rows[_models.name]!.single['output_tokens'] = 0,
    'duplicate Run occurrence': (s) =>
        s.rows[_outputs.name]!.first['sequence'] = 2,
    'foreign model provenance': (s) =>
        s.rows[_outputs.name]!.first['model_invocation_id'] = 'other-run-model',
    'changed proposal alias': (s) =>
        s.rows[_tools.name]!.first['alias'] = 'different-alias',
    'inconsistent Session authority': (s) =>
        s.identity['environment_task_id'] = 'different-task',
  }.entries) {
    test('${corruption.key} rejects the whole document', () async {
      storage.detailedRun();
      corruption.value(storage);
      await _expectUnpublishedFailure(collector, 'malformed_data');
    });
  }

  test('missing terminal root never becomes an empty Run', () async {
    storage.addRun('run');
    storage.rows[executionTables['root']!.name]!.clear();
    await _expectUnpublishedFailure(collector, 'malformed_data');
  });

  test(
    'total row bound accounts for rows already read before paging a table',
    () async {
      storage.countOverrides[chatEntries.name] = sessionEvidenceMaxRows - 1;
      await _expectUnpublishedFailure(collector, 'collection_limit');
      expect(storage.cursors[chatEntries.name], isNull);
    },
  );

  test(
    'total UTF-8 byte bound rejects individually readable rows atomically',
    () async {
      storage.entries(17, content: '\u00e9' * 500000);
      await _expectUnpublishedFailure(collector, 'collection_limit');
      expect(storage.cursors[chatEntries.name]!.length, greaterThan(1));
    },
  );

  test(
    'one oversized storage row fails without publishing preceding chunks',
    () async {
      storage.entries(2);
      storage.rows[chatEntries.name]![1]['content'] =
          'x' * relationalQueryByteLimit;
      await _expectUnpublishedFailure(collector, 'storage_query_failed');
      expect(storage.cursors[chatEntries.name], [null, 0]);
    },
  );

  test(
    'successful multi-chunk stream preserves Unicode and chunk bounds',
    () async {
      final content = 'x\u{1f600}' * sessionEvidenceChunkCodeUnits;
      storage.entries(1, content: content);
      final chunks = await collector.collectSession(_session).toList();
      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(chunk.length, lessThanOrEqualTo(sessionEvidenceChunkCodeUnits));
        expect(utf8.decode(utf8.encode(chunk)), chunk);
      }
      final document = await read();
      final entry =
          ((document['conversation'] as _Row)['entries'] as List).single
              as _Row;
      expect(entry['content'], content);
      expect(jsonDecode(chunks.join()), document);
    },
  );
}

Matcher _failure(String code) =>
    isA<SessionEvidenceFailure>().having((e) => e.code, 'code', code);

Future<void> _expectUnpublishedFailure(
  SessionEvaluatorService collector,
  String code,
) async {
  final chunks = <String>[];
  await expectLater(
    collector.collectSession(_session).map((chunk) {
      chunks.add(chunk);
      return chunk;
    }).drain<void>(),
    throwsA(_failure(code)),
  );
  expect(
    chunks,
    isEmpty,
    reason: 'No successful prefix may escape validation.',
  );
}

_Row _evidence(Map<String, Object?> document) =>
    ((document['runs'] as List).single as _Row)['evidence'] as _Row;

_Row _row(EvidenceTable table, _Row values) => {
  for (final column in table.columns) column: null,
  ...values,
};

_Row _chatEntry(int index, {String? content}) => {
  'session_id': _session,
  'entry_id': 'entry-$index',
  'role': index.isEven ? 'user' : 'assistant',
  'content': content ?? '  Entry $index\r\n',
  'run_id': null,
  'sequence': index,
};

_Row _model(
  String run,
  String id,
  int start,
  int terminal, [
  _Row overrides = const {},
]) => _row(_models, {
  'run_id': run,
  'invocation_id': id,
  'start_sequence': start,
  'terminal_sequence': terminal,
  'settlement': 'completed',
  'metadata_present': 1,
  'usage_present': 0,
  ...overrides,
});

/// Only the collector's finite SELECT shapes are supported. Real SQLite,
/// prepared backends and >1000-entry integration belong to the app suite.
final class _QueryFixture implements ProjectStorageService {
  _QueryFixture() {
    for (final table in _tables) {
      columns[table.name] = [...table.columns, ...table.excluded];
      rows[table.name] = [];
    }
    rows[chatSessions.name]!.add({
      'session_id': _session,
      'instructions': '  Keep exact instructions.\r\n',
      'max_model_invocations': 8,
      'next_entry': 0,
      'draft_request': '',
    });
  }

  static final _tables = [
    productRuns,
    chatSessions,
    chatEntries,
    ...executionTables.values,
  ];
  final _Row identity = {
    'session_id': _session,
    'strategy_id': 'dev.adele.strategy.chat',
    'task_id': 'task',
    'project_id': 'project',
    'task_title': 'Evidence fixture',
    'source_location': 'file:///project',
    'environment_id': 'environment',
    'environment_task_id': 'task',
    'environment_role': 'primary',
    'environment_provider_id': 'test.environment',
  };
  final versions = <String, List<Object?>>{
    'dev.adele.product': [1],
    'dev.adele.execution': [1],
    _chatOwner: [1],
  };
  final columns = <String, List<String>>{};
  final rows = <String, List<_Row>>{};
  final countOverrides = <String, int>{};
  final cursors = <String, List<Object?>>{};
  final queries = <String>[];
  final queriedOwners = <String>[];
  final violations = <String>[];
  bool Function(String sql, _Row parameters)? failQuery;

  void entries(int count, {String? content}) {
    rows[chatSessions.name]!.single['next_entry'] = count;
    rows[chatEntries.name] = [
      for (var i = 0; i < count; i++) _chatEntry(i, content: content),
    ];
  }

  void addRun(String id, {int latest = 2}) {
    rows[productRuns.name]!.add({
      'id': id,
      'session_id': _session,
      'terminal_state': 'completed',
    });
    final root = executionTables['root']!;
    rows[root.name]!.add(_row(root, {'run_id': id, 'latest_sequence': latest}));
    rows[executionTables['lifecycle']!.name]!.addAll([
      {'run_id': id, 'sequence': 0, 'state': 'created'},
      {'run_id': id, 'sequence': latest, 'state': 'completed'},
    ]);
  }

  void detailedRun() {
    addRun('run', latest: 30);
    rows[_models.name]!.add(_model('run', 'model', 2, 10));
    void output(int sequence, String kind, _Row payload) {
      rows[_outputs.name]!.add(
        _row(_outputs, {
          'run_id': 'run',
          'model_invocation_id': 'model',
          'sequence': sequence,
          'kind': kind,
          ...payload,
        }),
      );
    }

    output(3, 'text', {'text_content': '  Exact output.\r\n'});
    output(4, 'native', {
      'native_metadata_kind': 'provider.note',
      'presentation_kind': 'provider.safe',
      'presentation_compact_text': 'Safe summary',
      'presentation_data_json': '{ "summary": ["safe"] }',
    });
    for (var sequence = 5; sequence <= 9; sequence++) {
      output(sequence, 'toolProposal', {
        'provider_call_id': 'call-$sequence',
        'alias': 'inspect',
        'arguments_json': '{ "path": "source" }',
      });
    }
    void change(
      String id,
      int sequence,
      String kind, [
      _Row payload = const {},
    ]) {
      rows[_changes.name]!.add(
        _row(_changes, {
          'run_id': 'run',
          'tool_invocation_id': id,
          'sequence': sequence,
          'kind': kind,
          ...payload,
        }),
      );
    }

    const effects =
        '{"effects":["sourceRead"],"targets":["file:///source"],'
        '"summary":"Read source","uncertainty":"none"}';
    for (final (id, proposal, prepared, policy, disposition) in [
      ('executed', 5, 11, 'allow', 'success'),
      ('denied', 6, 15, 'deny', 'policyDenied'),
      ('user-rejected', 8, 18, 'ask', 'userRejected'),
    ]) {
      rows[_tools.name]!.add(
        _row(_tools, {
          'run_id': 'run',
          'invocation_id': id,
          'model_invocation_id': 'model',
          'tool_id': 'test.inspect',
          'alias': 'inspect',
          'provider_call_id': 'call-$proposal',
          'canonical_arguments_json': '{"path":"source","default":true}',
          'prepared_sequence': prepared,
          'proposal_sequence': proposal,
        }),
      );
      change(id, prepared, 'prepared');
      change(id, prepared + 1, 'policyEvaluated', {
        'policy_decision': policy,
        'effects_json': effects,
      });
      var completedAt = prepared + 2;
      if (policy == 'allow') {
        change(id, prepared + 2, 'executionStarted');
        completedAt++;
      } else if (policy == 'ask') {
        change(id, prepared + 2, 'approvalRequested', {
          'interruption_id': 'approval',
          'effects_json': effects,
        });
        change(id, prepared + 3, 'approvalResolved', {
          'interruption_id': 'approval',
          'approved': 0,
        });
        completedAt += 2;
      }
      change(id, completedAt, 'completed', {
        'outcome_disposition': disposition,
        'effect_certainty': policy == 'allow'
            ? 'knownOccurred'
            : 'knownNotOccurred',
        'model_content': 'Outcome $id',
        'host_data_json': '{}',
      });
    }
    rows[_rejections.name]!.add(
      _row(_rejections, {
        'run_id': 'run',
        'model_invocation_id': 'model',
        'provider_call_id': 'call-7',
        'alias': 'inspect',
        'arguments_json': '{"path":"source"}',
        'failure_kind': 'unknownAlias',
        'message': 'No binding.',
        'sequence': 23,
        'proposal_sequence': 7,
      }),
    );
  }

  void _require(bool valid, String message) {
    if (valid) return;
    violations.add(message);
    throw StateError(message);
  }

  Never _forbidden(String method) {
    violations.add(
      'Unexpected $method: only durable queryForSession is allowed.',
    );
    throw StateError('Read-only fixture.');
  }

  @override
  Future<bool> isDurableSession(String sessionId) async =>
      _forbidden('isDurableSession');

  @override
  Future<void> ensureSchemaForSession(
    String sessionId,
    List<String> migrations,
    ProjectStorageAccessMode accessMode,
  ) async => _forbidden('ensureSchemaForSession');

  @override
  Future<void> transactionForSession(
    String sessionId,
    List<RelationalStatement> statements,
    ProjectStorageAccessMode accessMode,
  ) async => _forbidden('transactionForSession');

  @override
  Future<List<RelationalRow>> queryForSession(
    String sessionId,
    String sql,
    _Row parameters,
    ProjectStorageAccessMode accessMode,
  ) async {
    final normalized = sql.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
    queries.add(normalized);
    _require(
      sessionId == _session && parameters[':session'] == _session,
      'Every query must use the requested Session and its named parameter.',
    );
    _require(
      accessMode == ProjectStorageAccessMode.durable,
      'Temporary storage must not substitute for retained evidence.',
    );
    final names = RegExp(
      r':[a-z_]+',
    ).allMatches(normalized).map((match) => match.group(0)!).toSet();
    _require(
      names.length == parameters.length && names.containsAll(parameters.keys),
      'Named parameter mismatch: $sql',
    );
    _require(
      normalized.startsWith('select ') &&
          !RegExp(r'\bselect\s+(?:\w+\.)?\*').hasMatch(normalized) &&
          !normalized.contains('offset') &&
          !normalized.contains(';'),
      'Expected explicit read-only keyset SELECT: $sql',
    );
    _require(
      RegExp(r'\blimit (1|2|128)$').hasMatch(normalized),
      'Every query must have a finite LIMIT: $sql',
    );
    if (failQuery?.call(normalized, parameters) ?? false) {
      throw StateError('Injected unavailable/retired storage.');
    }
    final result = _select(normalized, parameters);
    final bytes =
        2 +
        result.fold<int>(
          0,
          (size, row) =>
              size + utf8.encode(jsonEncode({'values': row})).length + 1,
        );
    if (bytes > relationalQueryByteLimit ||
        result.length > relationalQueryRowLimit) {
      throw StateError('Relational query response exceeds its bound.');
    }
    return [for (final row in result) RelationalRow(values: row)];
  }

  List<_Row> _select(String sql, _Row parameters) {
    if (sql.contains('from adele_product_sessions s ')) {
      _require(
        sql.contains('where s.id = :session order by ') &&
            !sql.contains('provider_state'),
        'Identity query must be scoped/safe.',
      );
      return [Map.of(identity)];
    }
    const sessionExists =
        'exists (select 1 from adele_product_sessions where id = :session)';
    if (sql.contains('from sqlite_master ')) {
      _require(
        sql.contains(sessionExists) &&
            sql.contains('order by name ') &&
            parameters[':type'] == 'table',
        'Invalid scoped table query.',
      );
      return columns.containsKey(parameters[':table'])
          ? [
              {'name': parameters[':table']},
            ]
          : [];
    }
    if (sql.contains('from pragma_table_info(:table) ')) {
      _require(
        sql.contains(sessionExists) && sql.contains('order by cid '),
        'Invalid scoped column query.',
      );
      return [
        for (final column in columns[parameters[':table']] ?? <String>[])
          {'name': column},
      ];
    }
    if (sql.contains('from adele_schema_versions ')) {
      _require(
        sql.contains('owner_id = :owner') &&
            sql.contains(sessionExists) &&
            sql.contains('order by owner_id '),
        'Invalid scoped owner query.',
      );
      queriedOwners.add(parameters[':owner'] as String);
      return [
        for (final version in versions[parameters[':owner']] ?? <Object?>[])
          {'version': version},
      ];
    }
    if (sql.contains('as foreign_run ')) {
      _require(
        sql.contains('id = :run and session_id <> :session') &&
            sql.contains(sessionExists),
        'Invalid foreign Run ownership query.',
      );
      return [
        {
          'foreign_run':
              rows[productRuns.name]!.any(
                (row) =>
                    row['id'] == parameters[':run'] &&
                    row['session_id'] != parameters[':session'],
              )
              ? 1
              : 0,
        },
      ];
    }
    final matches = _tables.where(
      (table) => sql.contains('from ${table.name} e '),
    );
    _require(matches.length == 1, 'Unsupported collector query: $sql');
    final table = matches.single;
    final execution = executionTables.values.contains(table);
    _require(
      execution
          ? sql.contains('join adele_product_runs r on r.id = e.run_id') &&
                sql.contains('r.session_id = :session') &&
                sql.contains('e.run_id = :run')
          : sql.contains('e.session_id = :session'),
      'Evidence query must explicitly scope Session and Run: $sql',
    );
    final scoped = rows[table.name]!
        .where(
          (row) => execution
              ? row['run_id'] == parameters[':run'] &&
                    rows[productRuns.name]!.any(
                      (run) =>
                          run['id'] == row['run_id'] &&
                          run['session_id'] == _session,
                    )
              : row['session_id'] == _session,
        )
        .toList();
    if (sql.startsWith('select count(*) as row_count ')) {
      return [
        {'row_count': countOverrides[table.name] ?? scoped.length},
      ];
    }
    _require(
      sql.contains('(:after is null or e.${table.key} > :after)') &&
          sql.contains('order by e.${table.key} limit 1') &&
          parameters.length == (execution ? 3 : 2) &&
          !sql.contains('<'),
      'Data pages must be ordered, exclusive keysets bounded to one row.',
    );
    (cursors[table.name] ??= []).add(parameters[':after']);
    final selected = sql
        .substring('select '.length, sql.indexOf(' from '))
        .split(',')
        .map((field) => field.trim().replaceFirst('e.', ''))
        .toList();
    _require(
      selected.every(table.columns.contains) &&
          !selected.any(table.excluded.contains),
      'Unexpected/opaque projection.',
    );
    int compare(Object? a, Object? b) => a is int && b is int
        ? a.compareTo(b)
        : (a as String).compareTo(b as String);
    scoped.sort((a, b) => compare(a[table.key], b[table.key]));
    final after = parameters[':after'];
    final page = scoped
        .where((row) => after == null || compare(row[table.key], after) > 0)
        .take(1);
    return [
      for (final row in page) {for (final field in selected) field: row[field]},
    ];
  }
}
