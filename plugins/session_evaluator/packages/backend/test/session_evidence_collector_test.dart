import 'dart:convert';

import 'package:adele_orchestration/adele_orchestration.dart';
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

  for (final sessionId in [
    '',
    ' ',
    '\t\n',
    ' $_session',
    '$_session ',
    ' $_session ',
    '\t$_session',
    '$_session\t',
    '\n$_session',
    '$_session\n',
  ]) {
    test(
      'invalid Session ${jsonEncode(sessionId)} fails before storage',
      () async {
        await expectLater(
          readSessionEvidence(collector, sessionId),
          throwsA(_failure('invalid_session')),
        );
        expect(storage.queries, isEmpty);
      },
    );
  }

  test('keyset pages retain every entry and Run-local identity', () async {
    storage.entries(4);
    for (final id in ['run-z', 'run-a']) {
      storage.addRun(id, latest: 5);
      storage.rows[_models.name]!.add(_model(id, 'same-model', 1, 3));
    }
    final document = await read();
    expect((document['identity'] as _Row)['session_id'], _session);
    expect(storage.queries, isNotEmpty);
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

  for (final field in [
    'project_id',
    'task_id',
    'session_id',
    'environment_id',
    'environment_task_id',
    'strategy_id',
  ]) {
    test('malformed retained $field rejects without publishing', () async {
      final original = storage.identity[field];
      for (final value in ['', ' $original\t']) {
        storage.identity[field] = value;
        await _expectUnpublishedFailure(collector, 'malformed_data');
      }
    });
  }

  test('Environment provider identity uses the public ID grammar', () async {
    for (final value in [
      '',
      'provider',
      'Dev.adele.provider',
      'dev..provider',
      'dev.adele.provider_name',
      ' dev.adele.provider ',
    ]) {
      storage.identity['environment_provider_id'] = value;
      await _expectUnpublishedFailure(collector, 'malformed_data');
    }
    storage.identity['environment_provider_id'] = 'dev.adele.provider-2';
    expect((await read())['identity'], storage.identity);
  });

  test(
    'valid graph metadata is preserved without identity normalization',
    () async {
      storage.identity.addAll({
        'project_id': 'Project 1',
        'task_id': 'Task 1',
        'environment_task_id': 'Task 1',
        'environment_id': 'Environment 1',
        'strategy_id': 'Strategy 1',
        'task_title': '  Exact title\t\n',
        'source_location': 'file:///old%20location/does-not-need-to-exist',
        'environment_role': 'additional',
      });
      final document = await read();
      expect(document['identity'], storage.identity);
      expect(
        (document['conversation'] as _Row)['status'],
        'unsupported_strategy',
      );
    },
  );

  test('title and role retain their distinct metadata constraints', () async {
    storage.identity['task_title'] = ' \t';
    await _expectUnpublishedFailure(collector, 'malformed_data');
    storage.identity['task_title'] = 'Valid title';
    for (final role in [' primary ', 'unknown']) {
      storage.identity['environment_role'] = role;
      await _expectUnpublishedFailure(collector, 'malformed_data');
    }
  });

  test('retained Project source follows durable URI constraints', () async {
    for (final source in [
      '',
      'relative/path',
      'https://example.test/project',
      'file://remote/project',
      'file:///project?query',
      'file:///project#fragment',
      'file:////project',
      'file:///project/%00',
      'file:///project/%5C',
      'file:///project/%2F',
      'file:///project/%FF',
      'file:///invalid%escape',
    ]) {
      storage.identity['source_location'] = source;
      await _expectUnpublishedFailure(collector, 'malformed_data');
    }
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
        (document['coverage'] as _Row)['retained_session_evidence'],
        status == 'available' ? 'complete_retained_evidence' : 'partial',
      );
      expect((document['coverage'] as _Row)['status'], 'partial');
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
      expect(
        (document['coverage'] as _Row)['retained_session_evidence'],
        'partial',
      );
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

  test(
    'ToolId and provider-native IDs preserve permitted outer whitespace',
    () async {
      storage.detailedRun();
      final tool = storage.rows[_tools.name]!.first;
      tool['tool_id'] = ToolId(' \ttest.inspect\n').value;
      final proposal = ProviderToolProposal(
        providerCallId: ' call-5\t',
        alias: 'inspect',
        arguments: const {},
      );
      tool['provider_call_id'] = proposal.providerCallId;
      storage.rows[_outputs.name]!.singleWhere(
        (r) => r['sequence'] == 5,
      )['provider_call_id'] = proposal.providerCallId;
      storage.rows[_outputs.name]!.first['provider_item_id'] = ModelTextOutput(
        'Text',
        providerItemId: ' item\n',
      ).providerItemId;
      final metadata = ModelTerminalMetadata(
        providerRequestId: ' request ',
        providerResponseId: '\tresponse ',
      );
      storage.rows[_models.name]!.single.addAll({
        'provider_request_id': metadata.providerRequestId,
        'provider_response_id': metadata.providerResponseId,
      });
      final evidence = _evidence(await read());
      expect(evidence['tool_invocations'], storage.rows[_tools.name]);
      expect(evidence['model_invocations'], storage.rows[_models.name]);
      expect(evidence['model_outputs'], storage.rows[_outputs.name]);
    },
  );

  test('blank Tool IDs remain malformed', () async {
    storage.detailedRun();
    for (final value in ['', ' \t\n']) {
      expect(() => ToolId(value), throwsFormatException);
      storage.rows[_tools.name]!.first['tool_id'] = value;
      await _expectUnpublishedFailure(collector, 'malformed_data');
    }
  });

  test(
    'deep canonical arguments, outcome data and failure details are valid',
    () async {
      storage.detailedRun();
      final deep = _nestedData(80);
      final outcome = ToolOutcome(
        disposition: ToolOutcomeDisposition.success,
        effectCertainty: EffectCertainty.knownOccurred,
        modelContent: 'Retained outcome',
        hostData: deep,
      );
      final failure = ActivityFailure(
        kind: 'FixtureFailure',
        message: 'Retained failure',
        providerDetails: deep,
      );
      final encoded = jsonEncode(deep);
      storage.rows[_tools.name]!.first['canonical_arguments_json'] = encoded;
      storage.rows[_changes.name]!.firstWhere(
        (r) => r['kind'] == 'completed',
      )['host_data_json'] = jsonEncode(
        outcome.hostData,
      );
      final failureFields = {
        'failure_kind': failure.kind,
        'failure_message': failure.message,
        'failure_provider_details_json': jsonEncode(failure.providerDetails),
      };
      storage.rows[productRuns.name]!.single['terminal_state'] = 'failed';
      storage.rows[executionTables['lifecycle']!.name]!.last['state'] =
          'failed';
      storage.rows[executionTables['root']!.name]!.single.addAll(failureFields);
      storage.rows[_models.name]!.add(
        _model('run', 'failed-model', 24, 25, {
          'settlement': null,
          'metadata_present': 0,
          ...failureFields,
        }),
      );
      final evidence = _evidence(await read());
      expect(evidence['tool_invocations'], storage.rows[_tools.name]);
      expect(evidence['tool_changes'], storage.rows[_changes.name]);
      expect(
        evidence['root'],
        storage.rows[executionTables['root']!.name]!.single,
      );
      expect(evidence['model_invocations'], storage.rows[_models.name]);
    },
  );

  for (final owner in ['proposal', 'usage', 'presentation']) {
    test('$owner depth bound counts containers, not scalar leaves', () async {
      storage.detailedRun();
      _Row snapshot(_Row data) => switch (owner) {
        'proposal' => ProviderToolProposal(
          providerCallId: 'call',
          alias: 'tool',
          arguments: data,
        ).arguments,
        'usage' => ModelUsage(providerDetails: data).providerDetails,
        _ => ModelNativePresentation(
          kind: 'summary',
          compactText: 'Safe',
          data: data,
        ).data,
      };
      final field = switch (owner) {
        'proposal' => 'arguments_json',
        'usage' => 'usage_provider_details_json',
        _ => 'presentation_data_json',
      };
      final row = switch (owner) {
        'proposal' => storage.rows[_outputs.name]!.last,
        'usage' => storage.rows[_models.name]!.single,
        _ => storage.rows[_outputs.name]!.singleWhere(
          (r) => r['kind'] == 'native',
        ),
      };
      if (owner == 'usage') row['usage_present'] = 1;
      // Root is depth 0: 64 containers with a scalar at depth 64 is valid.
      row[field] = jsonEncode(snapshot(_nestedData(64)));
      final evidence = _evidence(await read());
      expect(
        evidence[owner == 'usage' ? 'model_invocations' : 'model_outputs'],
        storage.rows[owner == 'usage' ? _models.name : _outputs.name],
      );
      for (final data in [
        _nestedData(65),
        _nestedData(64, leaf: <String, Object?>{}),
      ]) {
        expect(() => snapshot(data), throwsFormatException);
        row[field] = jsonEncode(data);
        await _expectUnpublishedFailure(collector, 'malformed_data');
      }
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
    'overdeep proposal JSON': (s) =>
        s.rows[_outputs.name]!.last['arguments_json'] = jsonEncode(
          _nestedData(65),
        ),
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

  group('retained command transcripts', () {
    test(
      'absent schema is unavailable, never empty-complete or initialized',
      () async {
        final document = await read();
        expect(document['schema'], 'dev.adele.session-evidence.v2');
        expect(document['command_tools'], {
          'status': 'unavailable',
          'schema_version': null,
          'captures': <_Row>[],
        });
        expect(_commandCoverage(document), {
          'status': 'unavailable',
          'invocations_without_capture': <_Row>[],
        });
        expect(
          (document['coverage'] as _Row)['retained_session_evidence'],
          'complete_retained_evidence',
        );
        expect((document['coverage'] as _Row)['status'], 'partial');
        expect(storage.queriedOwners, contains(commandSchemaOwner));
        expect(storage.headerCursors, isEmpty);
        expect(storage.chunkQueries, isEmpty);
        expect(storage.versions, isNot(contains(commandSchemaOwner)));
      },
    );

    test('initialized empty schema is available and complete', () async {
      storage.commandSchema();
      final document = await read();
      expect(document['command_tools'], {
        'status': 'available',
        'schema_version': 1,
        'captures': <_Row>[],
      });
      expect(_commandCoverage(document), {
        'status': 'complete_retained_captures',
        'invocations_without_capture': <_Row>[],
      });
      expect(
        (document['coverage'] as _Row)['status'],
        'complete_retained_evidence',
      );
      expect(storage.headerCursors, [(null, null)]);
      expect(storage.chunkQueries, isEmpty);
      expect(storage.finalHeaderQueries, isEmpty);
    });

    for (final sample in <String, List<(String, String)>>{
      'empty complete': [],
      'stdout only': [('stdout', 'out without newline')],
      'stderr only': [('stderr', 'error\r\n')],
      'interleaved controls and Unicode': [
        ('stdout', '  \x1b[31mred\x1b[0m\r\n\x00\t"\\'),
        ('stderr', '\u00e9\u0301\u{1f600}\u2028\rprogress'),
        ('stdout', 'partial'),
        ('stderr', ' line\n'),
      ],
      'maximal UTF-16 chunk': [('stdout', '\u{1f600}' * 2048)],
    }.entries) {
      test(
        '${sample.key} preserves exact header, pipe order and text',
        () async {
          final header = storage.capture(output: sample.value);
          storage.commandRun(header: header);
          final document = await read();
          expect(_captures(document), [
            {
              'header': header,
              'chunks': [
                for (var i = 0; i < sample.value.length; i++)
                  {
                    'position': i + 1,
                    'stream': sample.value[i].$1,
                    'text': sample.value[i].$2,
                  },
              ],
              'completeness': 'complete',
              'terminal_provenance': 'matched',
              'consistency': 'committed_high_water_snapshot',
            },
          ]);
          expect(
            _commandCoverage(document)['status'],
            'complete_retained_captures',
          );
          expect(
            (document['coverage'] as _Row)['status'],
            'complete_retained_evidence',
          );
          expect(storage.finalHeaderQueries, hasLength(1));
          expect(storage.chunkQueries, hasLength(sample.value.isEmpty ? 0 : 1));
          expect(jsonEncode(document), isNot(contains('chunk_count')));
          expect(jsonEncode(document), isNot(contains('first_position')));
          expect(jsonEncode(document), isNot(contains('last_position')));
        },
      );
    }

    test('canonical metadata remains verbatim rather than normalized', () async {
      final header = storage.capture(
        overrides: {
          'program': '  executable \t',
          'arguments_json':
              '[ "", "  spaced  ", "\\t", "\\u00e9", "\\ud83d\\ude00" ]',
          'working_directory': 'source/with space',
          'timeout_seconds': 600,
        },
      );
      storage.commandRun(header: header);
      // Raw model arguments are not the canonical prepared invocation metadata.
      storage.rows[_outputs.name]!.single['arguments_json'] = '{}';
      final document = await read();
      expect(_captures(document).single['header'], header);
      expect(_captures(document).single['terminal_provenance'], 'matched');
      expect(
        (_evidence(document)['model_outputs'] as List).single,
        containsPair('arguments_json', '{}'),
      );
    });

    for (final (termination, exitCode) in [
      ('exited', -1),
      ('exited', 17),
      ('timedOut', null),
    ]) {
      test(
        '$termination/$exitCode completeness is independent of Run success',
        () async {
          final header = storage.capture(
            overrides: {'termination': termination, 'exit_code': exitCode},
          );
          storage.commandRun(header: header);
          final document = await read();
          expect(_captures(document).single['header'], header);
          expect(_captures(document).single['completeness'], 'complete');
          expect(
            (document['runs'] as List).single,
            containsPair('terminal_state', 'completed'),
          );
          expect(
            (document['coverage'] as _Row)['status'],
            'complete_retained_evidence',
          );
        },
      );
    }

    test(
      'composite pages retain several captures and reused invocation IDs',
      () async {
        for (final (run, id) in [
          ('run-z', 'same'),
          ('run-a', 'z'),
          ('run-a', 'same'),
          ('run-a', 'a'),
        ]) {
          storage.capture(
            run: run,
            invocation: id,
            output: [('stdout', '$run/$id')],
          );
        }
        final document = await read();
        final captures = _captures(document);
        expect(
          captures.map(
            (c) => (
              (c['header'] as _Row)['run_id'],
              (c['header'] as _Row)['invocation_id'],
            ),
          ),
          [
            ('run-a', 'a'),
            ('run-a', 'same'),
            ('run-z', 'same'),
            ('run-a', 'z'),
          ],
        );
        expect(storage.headerCursors, [
          (null, null),
          ('a', 'run-a'),
          ('same', 'run-a'),
          ('same', 'run-z'),
          ('z', 'run-a'),
        ]);
        for (final capture in captures) {
          final header = capture['header'] as _Row;
          expect(
            (capture['chunks'] as List).single,
            containsPair(
              'text',
              '${header['run_id']}/${header['invocation_id']}',
            ),
          );
          expect(
            capture['terminal_provenance'],
            'terminal_evidence_unavailable',
          );
        }
        expect(document['runs'], isEmpty);
        expect(_commandCoverage(document)['status'], 'partial');
      },
    );

    test(
      'same invocation in different retained Runs matches only its own capture',
      () async {
        final header = storage.capture(
          run: 'a',
          invocation: 'same',
          output: [('stdout', 'from a')],
        );
        storage.commandRun(run: 'a', invocation: 'same', header: header);
        storage.commandRun(run: 'b', invocation: 'same');
        final document = await read();
        expect(_captures(document).single['terminal_provenance'], 'matched');
        expect(_commandCoverage(document), {
          'status': 'partial',
          'invocations_without_capture': [
            {'run_id': 'b', 'invocation_id': 'same', 'execution': 'started'},
          ],
        });
      },
    );

    test(
      'many interleaved Session headers traverse every composite key once',
      () async {
        final expected = <(String, String)>[];
        for (var index = 0; index < 40; index++) {
          final invocation = 'command-${index.toString().padLeft(2, '0')}';
          for (final run in ['run-a', 'run-m', 'run-z']) {
            expected.add((invocation, run));
          }
        }
        // Insert opposite to enumeration order, with foreign captures sharing the
        // leading invocation key. Run-first enumeration would produce another list.
        for (final (invocation, run) in expected.reversed) {
          storage.capture(
            run: run,
            invocation: invocation,
            output: [('stdout', '$invocation/$run'), ('stderr', '\r\n')],
          );
        }
        for (var index = 0; index < 40; index++) {
          storage.capture(
            run: 'run-b',
            invocation: 'command-${index.toString().padLeft(2, '0')}',
            session: 'other-session',
            output: [('stdout', 'SECRET-FOREIGN')],
          );
        }
        final document = await read();
        final captures = _captures(document);
        expect(captures, hasLength(expected.length));
        expect(
          captures.map((capture) {
            final header = capture['header'] as _Row;
            return (header['invocation_id'], header['run_id']);
          }),
          expected,
        );
        expect(storage.headerCursors, [(null, null), ...expected]);
        expect(storage.finalHeaderQueries, hasLength(expected.length));
        for (var i = 0; i < captures.length; i++) {
          expect(captures[i]['chunks'], [
            {
              'position': 1,
              'stream': 'stdout',
              'text': '${expected[i].$1}/${expected[i].$2}',
            },
            {'position': 2, 'stream': 'stderr', 'text': '\r\n'},
          ]);
        }
        expect(jsonEncode(document), isNot(contains('SECRET-FOREIGN')));
      },
    );

    for (final addition in [false, true]) {
      test(
        'concurrent ${addition ? 'addition' : 'removal'} beyond the cursor fails the discovery count',
        () async {
          storage.capture(invocation: 'a');
          storage.capture(invocation: 'z');
          storage.beforeQuery = (sql, parameters) {
            if (parameters[':after_invocation'] != 'a') return;
            storage.beforeQuery = null;
            if (addition) {
              storage.capture(invocation: 'm');
            } else {
              storage.rows[commandCaptures.name]!.removeWhere(
                (row) => row['invocation_id'] == 'z',
              );
            }
          };
          await _expectUnpublishedFailure(collector, 'malformed_data');
          expect(storage.headerCursors, [
            (null, null),
            ('a', 'run'),
            if (addition) ...[('m', 'run'), ('z', 'run')],
          ]);
        },
      );
    }

    test(
      'successor query failure does not emit an already read capture',
      () async {
        storage.capture(invocation: 'a', output: [('stdout', 'retained')]);
        storage.capture(invocation: 'b');
        storage.failQuery = (_, parameters) =>
            parameters[':after_invocation'] == 'a';
        await _expectUnpublishedFailure(collector, 'storage_query_failed');
        expect(storage.finalHeaderQueries, hasLength(1));
      },
    );

    test(
      'other Session headers, chunks and Runs cannot leak into export',
      () async {
        storage.capture(output: [('stdout', 'ours')]);
        storage.capture(
          run: 'foreign-run',
          session: 'other-session',
          output: [('stderr', 'SECRET-FOREIGN')],
          overrides: {'state': 'malformed'},
        );
        storage.rows[productRuns.name]!.add({
          'id': 'foreign-run',
          'session_id': 'other-session',
          'terminal_state': 'failed',
        });
        // An unassociated orphan is not evidence attributable to this Session.
        storage.rows[commandChunks.name]!.add({
          'run_id': 'orphan',
          'invocation_id': 'command',
          'position': 1,
          'stream': 'invalid',
          'text': 'SECRET-ORPHAN',
        });
        final document = await read();
        expect(_captures(document), hasLength(1));
        expect(document['runs'], isEmpty);
        expect(jsonEncode(document), isNot(contains('SECRET-')));
        expect(storage.chunkQueries.single[':run'], 'run');
        expect(storage.headerCursors, [(null, null), ('command', 'run')]);
      },
    );

    for (final chat in ['unavailable', 'unsupported_strategy']) {
      test(
        'command capture without terminal Run remains available with Chat $chat',
        () async {
          final header = storage.capture(
            output: [('stdout', 'retained independently')],
          );
          if (chat == 'unavailable') {
            storage.versions.remove(_chatOwner);
            storage.columns.remove(chatSessions.name);
            storage.columns.remove(chatEntries.name);
          } else {
            storage.identity['strategy_id'] = 'test.other-strategy';
          }
          final document = await read();
          expect((document['conversation'] as _Row)['status'], chat);
          expect(document['runs'], isEmpty);
          expect(_captures(document).single['header'], header);
          expect(
            _captures(document).single['terminal_provenance'],
            'terminal_evidence_unavailable',
          );
          expect(_commandCoverage(document)['status'], 'partial');
          expect((document['coverage'] as _Row)['status'], 'partial');
        },
      );
    }

    for (final available in [false, true]) {
      for (final (execution, classification) in [
        ('prepared', 'not_observed'),
        ('denied', 'not_executed'),
        ('rejected', 'not_executed'),
        ('started', 'started'),
      ]) {
        test(
          'missing $execution capture is $classification with schema ${available ? 'available' : 'absent'}',
          () async {
            if (available) storage.commandSchema();
            storage.commandRun(execution: execution);
            final document = await read();
            final status = !available
                ? 'unavailable'
                : classification == 'not_executed'
                ? 'complete_retained_captures'
                : 'partial';
            expect(_commandCoverage(document), {
              'status': status,
              'invocations_without_capture': [
                {
                  'run_id': 'run',
                  'invocation_id': 'command',
                  'execution': classification,
                },
              ],
            });
            expect(_captures(document), isEmpty);
            expect(
              (document['coverage'] as _Row)['status'],
              status == 'complete_retained_captures'
                  ? 'complete_retained_evidence'
                  : 'partial',
            );
          },
        );
      }
    }

    test(
      'a matching alias is not the Command Tools semantic identity',
      () async {
        storage.commandSchema();
        storage.commandRun();
        storage.rows[_tools.name]!.single['tool_id'] = 'test.other-command';
        final document = await read();
        expect(_commandCoverage(document), {
          'status': 'complete_retained_captures',
          'invocations_without_capture': <_Row>[],
        });
      },
    );

    for (final state in ['capturing', 'failed']) {
      for (final empty in [false, true]) {
        test(
          '$state ${empty ? 'empty' : 'committed prefix'} never invents liveness or completion',
          () async {
            final header = storage.capture(
              output: empty
                  ? []
                  : [('stdout', 'partial\r'), ('stderr', '\u{1f600}')],
              overrides: {
                'state': state,
                'termination': null,
                'exit_code': null,
                'failure': state == 'failed'
                    ? 'Exact capture write failure.'
                    : null,
              },
            );
            storage.commandRun(header: header);
            final document = await read();
            final capture = _captures(document).single;
            expect(capture['header'], header);
            expect(capture['chunks'], hasLength(empty ? 0 : 2));
            expect(
              capture['completeness'],
              state == 'failed' ? 'incomplete' : 'unsealed_liveness_unknown',
            );
            expect(capture['terminal_provenance'], 'matched');
            expect(_commandCoverage(document)['status'], 'partial');
            expect((document['coverage'] as _Row)['status'], 'partial');
            expect(jsonEncode(capture), isNot(contains('interrupted')));
          },
        );
      }
    }

    for (final corruption in <String, void Function(_QueryFixture)>{
      'wrong semantic tool with matching alias': (s) =>
          s.rows[_tools.name]!.single['tool_id'] = 'test.other-command',
      'padded semantic tool identity': (s) =>
          s.rows[_tools.name]!.single['tool_id'] = ' $commandToolId ',
      'unmatched invocation': (s) =>
          s.rows[commandCaptures.name]!.single['invocation_id'] = 'other',
      'no executionStarted': (s) => s.rows[_changes.name]!.removeWhere(
        (r) => r['kind'] == 'executionStarted',
      ),
      'program mismatch': (s) =>
          s.rows[commandCaptures.name]!.single['program'] = 'other',
      'argv value mismatch': (s) =>
          s.rows[commandCaptures.name]!.single['arguments_json'] =
              '["other", ""]',
      'argv order mismatch': (s) =>
          s.rows[commandCaptures.name]!.single['arguments_json'] =
              '["", "hello"]',
      'argv length mismatch': (s) =>
          s.rows[commandCaptures.name]!.single['arguments_json'] = '["hello"]',
      'working directory mismatch': (s) =>
          s.rows[commandCaptures.name]!.single['working_directory'] = 'other',
      'timeout mismatch': (s) =>
          s.rows[commandCaptures.name]!.single['timeout_seconds'] = 31,
      'foreign Environment': (s) =>
          s.rows[commandCaptures.name]!.single['environment_id'] =
              'foreign-environment',
    }.entries) {
      test(
        '${corruption.key} fails instead of downgrading provenance',
        () async {
          final header = storage.capture();
          storage.commandRun(header: header);
          corruption.value(storage);
          await _expectUnpublishedFailure(collector, 'malformed_data');
        },
      );
    }

    test(
      'capture linked to another Session terminal Run fails atomically',
      () async {
        storage.capture();
        storage.rows[productRuns.name]!.add({
          'id': 'run',
          'session_id': 'other',
          'terminal_state': 'completed',
        });
        await _expectUnpublishedFailure(collector, 'malformed_data');
        expect(storage.chunkQueries, isEmpty);
      },
    );

    for (final finalRead in [false, true]) {
      test(
        'foreign Session returned in ${finalRead ? 'final' : 'initial'} header fails',
        () async {
          storage.capture();
          storage.afterSelect = (sql, parameters, result) {
            if (sql.contains('as chunk_count') &&
                parameters.containsKey(':run') == finalRead) {
              for (final row in result) {
                row['session_id'] = 'foreign';
              }
            }
          };
          await _expectUnpublishedFailure(collector, 'malformed_data');
        },
      );
    }

    for (final (field, values) in <(String, List<Object?>)>[
      ('run_id', ['', ' run ']),
      ('invocation_id', ['', '\tcommand']),
      ('environment_id', ['', ' environment ']),
      ('program', [null, 7, '', 'nul\x00', '\ud800']),
      (
        'arguments_json',
        ['{bad', '{}', '[1]', '[null]', '["\\u0000"]', '["\\udfff"]'],
      ),
      (
        'working_directory',
        [
          '/',
          '/abs',
          'a/',
          'a//b',
          '.',
          '..',
          'a/../b',
          'a/./b',
          'nul\x00',
          '\ud800',
        ],
      ),
      ('timeout_seconds', [null, '30', 0, 601]),
      ('version', [null, '1', 0, -1]),
      ('high_water', [null, '0', -1, 1]),
      ('total_code_units', [null, '0', -1, 1]),
      ('state', ['interrupted', 'unknown', null]),
      ('termination', ['unknown', null]),
      ('exit_code', [null, '0']),
      ('failure', ['', 'unexpected complete failure', 1]),
    ]) {
      for (final value in values) {
        test(
          'invalid command $field=${jsonEncode(value)} is rejected',
          () async {
            storage.capture(overrides: {field: value});
            await _expectUnpublishedFailure(collector, 'malformed_data');
          },
        );
      }
    }

    for (final outcome in <_Row>[
      {'state': 'capturing', 'termination': 'exited', 'exit_code': 0},
      {'state': 'capturing', 'termination': null, 'exit_code': 0},
      {
        'state': 'capturing',
        'termination': null,
        'exit_code': null,
        'failure': 'failed',
      },
      {'state': 'complete', 'termination': 'timedOut', 'exit_code': 0},
      {
        'state': 'failed',
        'termination': null,
        'exit_code': null,
        'failure': null,
      },
      {
        'state': 'failed',
        'termination': null,
        'exit_code': null,
        'failure': '',
      },
      {
        'state': 'failed',
        'termination': 'exited',
        'exit_code': null,
        'failure': 'failed',
      },
    ]) {
      test(
        'contradictory capture outcome ${jsonEncode(outcome)} fails',
        () async {
          storage.capture(overrides: outcome);
          await _expectUnpublishedFailure(collector, 'malformed_data');
        },
      );
    }

    test(
      'metadata admission bound is enforced before chunk collection',
      () async {
        storage.capture(overrides: {'program': 'p' * (128 * 1024)});
        await _expectUnpublishedFailure(collector, 'malformed_data');
        expect(storage.chunkQueries, isEmpty);
      },
    );

    test('unsupported SQL scalar fails at the storage boundary', () async {
      storage.capture(overrides: {'exit_code': 0.5});
      await _expectUnpublishedFailure(collector, 'storage_query_failed');
    });

    for (var mask = 1; mask < 7; mask++) {
      test('partial Command schema presence $mask is incompatible', () async {
        storage.commandSchema();
        if (mask & 1 == 0) storage.versions.remove(commandSchemaOwner);
        if (mask & 2 == 0) storage.columns.remove(commandCaptures.name);
        if (mask & 4 == 0) storage.columns.remove(commandChunks.name);
        await _expectUnpublishedFailure(collector, 'incompatible_schema');
        expect(storage.headerCursors, isEmpty);
      });
    }
    for (final version in <List<Object?>>[
      [0],
      [2],
      ['1'],
      [null],
      [1, 1],
    ]) {
      test('Command owner version $version is incompatible', () async {
        storage.commandSchema();
        storage.versions[commandSchemaOwner] = version;
        await _expectUnpublishedFailure(collector, 'incompatible_schema');
      });
    }
    for (final table in [commandCaptures, commandChunks]) {
      for (final column in table.columns) {
        test('missing ${table.name}.$column is incompatible', () async {
          storage.commandSchema();
          storage.columns[table.name]!.remove(column);
          await _expectUnpublishedFailure(collector, 'incompatible_schema');
        });
      }
    }

    for (final corruption in <String, void Function(_QueryFixture)>{
      'missing chunk': (s) => s.rows[commandChunks.name]!.removeLast(),
      'extra chunk': (s) => s.rows[commandChunks.name]!.add({
        ...s.rows[commandChunks.name]!.last,
        'position': 5,
      }),
      'first position zero': (s) =>
          s.rows[commandChunks.name]!.first['position'] = 0,
      'gap with last position beyond extent': (s) =>
          s.rows[commandChunks.name]!.last['position'] = 5,
      'duplicate interior position despite valid COUNT/MIN/MAX': (s) =>
          s.rows[commandChunks.name]![2]['position'] = 2,
      'foreign chunk Run': (s) =>
          s.rows[commandChunks.name]!.last['run_id'] = 'foreign',
      'foreign chunk invocation': (s) =>
          s.rows[commandChunks.name]!.last['invocation_id'] = 'foreign',
      'invalid stream': (s) =>
          s.rows[commandChunks.name]!.first['stream'] = 'combined',
      'null stream': (s) => s.rows[commandChunks.name]!.first['stream'] = null,
      'empty text': (s) => s.rows[commandChunks.name]!.first['text'] = '',
      'nontext output': (s) => s.rows[commandChunks.name]!.first['text'] = 7,
      'null text': (s) => s.rows[commandChunks.name]!.first['text'] = null,
      '4097 code units': (s) =>
          s.rows[commandChunks.name]!.first['text'] = 'x' * 4097,
      'unpaired high surrogate': (s) =>
          s.rows[commandChunks.name]!.first['text'] = '\ud800',
      'unpaired low surrogate': (s) =>
          s.rows[commandChunks.name]!.first['text'] = '\udfff',
      'text sum too short': (s) =>
          s.rows[commandCaptures.name]!.single['total_code_units'] = 7,
      'text sum too long': (s) =>
          s.rows[commandCaptures.name]!.single['total_code_units'] = 9,
      'impossible lower extent': (s) =>
          s.rows[commandCaptures.name]!.single['total_code_units'] = 3,
      'impossible upper extent': (s) =>
          s.rows[commandCaptures.name]!.single['total_code_units'] =
              4 * 4096 + 1,
    }.entries) {
      test(
        'command ${corruption.key} fails without any emitted prefix',
        () async {
          storage.capture(output: List.generate(4, (_) => ('stdout', 'ab')));
          corruption.value(storage);
          await _expectUnpublishedFailure(collector, 'malformed_data');
        },
      );
    }

    test('UTF-16 extent cannot be replaced by Unicode scalar count', () async {
      storage.capture(
        output: [('stdout', '\u{1f600}')],
        overrides: {'total_code_units': 1},
      );
      await _expectUnpublishedFailure(collector, 'malformed_data');
    });

    test('empty high-water cannot hide stored chunks', () async {
      storage.capture(
        output: [('stdout', 'hidden')],
        overrides: {'high_water': 0, 'total_code_units': 0},
      );
      await _expectUnpublishedFailure(collector, 'malformed_data');
      expect(storage.chunkQueries, isEmpty);
    });

    test(
      'chunks disappearing after the initial extent cannot export a prefix',
      () async {
        storage.capture(output: List.generate(33, (_) => ('stdout', 'x')));
        storage.beforeQuery = (sql, parameters) {
          if (sql.startsWith('select c.position') &&
              parameters[':after'] == 32) {
            storage.rows[commandChunks.name]!.removeLast();
          }
        };
        await _expectUnpublishedFailure(collector, 'malformed_data');
        expect(storage.chunkQueries.map((q) => q[':after']), [0, 32]);
        expect(storage.finalHeaderQueries, isEmpty);
      },
    );

    test(
      'maximally escaped chunks use multiple host-safe 32-row pages',
      () async {
        final output = List.generate(
          65,
          (i) => (i.isEven ? 'stdout' : 'stderr', '\x00' * 4096),
        );
        final header = storage.capture(
          invocation: 'i' * 100000,
          output: output,
        );
        final chunks = await collector.collectSession(_session).toList();
        final document = jsonDecode(chunks.join()) as _Row;
        expect(storage.chunkQueries.map((q) => q[':after']), [0, 32, 64]);
        expect(
          storage.chunkQueries.map((q) => q[':high_water']),
          everyElement(65),
        );
        expect(
          storage.responseBytes,
          everyElement(lessThan(relationalQueryByteLimit)),
        );
        expect(chunks, hasLength(greaterThan(1)));
        expect(
          chunks.map((c) => c.length),
          everyElement(lessThanOrEqualTo(sessionEvidenceChunkCodeUnits)),
        );
        final retained = (_captures(document).single['chunks'] as List)
            .cast<_Row>();
        expect(
          retained.map((c) => c['position']),
          List.generate(65, (i) => i + 1),
        );
        expect(retained.map((c) => (c['stream'], c['text'])), output);
        expect(retained.every((c) => c.keys.toSet().length == 3), isTrue);
        expect(_captures(document).single['header'], header);
      },
    );

    for (final phase in ['headers', 'chunks', 'final header']) {
      test('$phase query failure never exports earlier evidence', () async {
        storage.entries(1, content: 'already collected' * 1000);
        storage.capture(output: [('stdout', 'committed')]);
        storage.failQuery = (sql, parameters) => switch (phase) {
          'headers' =>
            sql.contains('as chunk_count') && !parameters.containsKey(':run'),
          'chunks' => sql.startsWith('select c.position'),
          _ => sql.contains('as chunk_count') && parameters.containsKey(':run'),
        };
        await _expectUnpublishedFailure(collector, 'storage_query_failed');
      });
    }

    for (final extent in ['headers', 'chunks']) {
      test('command $extent preflight shares the total row budget', () async {
        storage.capture();
        if (extent == 'headers') {
          storage.countOverrides[commandCaptures.name] = sessionEvidenceMaxRows;
        } else {
          storage.afterSelect = (sql, parameters, result) {
            if (sql.contains('as chunk_count')) {
              result.single.addAll({
                'high_water': sessionEvidenceMaxRows,
                'total_code_units': sessionEvidenceMaxRows,
                'chunk_count': sessionEvidenceMaxRows,
                'first_position': 1,
                'last_position': sessionEvidenceMaxRows,
              });
            }
          };
        }
        await _expectUnpublishedFailure(collector, 'collection_limit');
        expect(storage.chunkQueries, isEmpty);
      });
    }

    test(
      'command encoded bytes can exceed the shared limit despite valid decoded extent',
      () async {
        storage.capture(
          output: List.generate(700, (_) => ('stdout', '\x00' * 4096)),
        );
        await _expectUnpublishedFailure(collector, 'collection_limit');
        expect(storage.chunkQueries.length, greaterThan(1));
        expect(
          storage.responseBytes,
          everyElement(lessThan(relationalQueryByteLimit)),
        );
        expect(storage.collectedBytes, greaterThan(sessionEvidenceMaxBytes));
        expect(storage.finalHeaderQueries, isEmpty);
      },
    );

    test(
      'command decoded extent preflight accounts for earlier evidence bytes',
      () async {
        storage.entries(16, content: 'x' * 1000000);
        storage.capture(
          output: List.generate(200, (_) => ('stdout', 'x' * 4096)),
        );
        await _expectUnpublishedFailure(collector, 'collection_limit');
        expect(storage.cursors[chatEntries.name], hasLength(17));
        expect(storage.chunkQueries, isEmpty);
      },
    );

    test(
      'final command validation rows still count after a full chunk budget',
      () async {
        storage.capture();
        await read();
        // Model a large valid extent without making the finite adapter scan
        // 100,000 stored rows for every page. The final reread is the excess row.
        final highWater = sessionEvidenceMaxRows - storage.returnedRows + 1;
        storage.returnedRows = 0;
        storage.finalHeaderQueries.clear();
        storage.afterSelect = (sql, parameters, result) {
          if (sql.contains('as chunk_count')) {
            result.single.addAll({
              'high_water': highWater,
              'total_code_units': highWater,
              'chunk_count': highWater,
              'first_position': 1,
              'last_position': highWater,
            });
          } else if (sql.startsWith('select c.position')) {
            final after = parameters[':after'] as int;
            result.addAll([
              for (
                var position = after + 1;
                position <= highWater && position <= after + 32;
                position++
              )
                {'position': position, 'stream': 'stdout', 'text': 'x'},
            ]);
          }
        };
        await _expectUnpublishedFailure(collector, 'collection_limit');
        expect(storage.returnedRows, sessionEvidenceMaxRows + 1);
        expect(storage.finalHeaderQueries, hasLength(1));
      },
    );

    test(
      'final JSON bound rejects command coverage expansion without emissions',
      () async {
        storage.entries(17, content: 'x');
        storage.capture(run: 'unretained', output: [('stdout', 'retained')]);
        storage.commandRun(invocation: 'i' * 100000, execution: 'prepared');
        final baseline = await read();
        final documentBytes = utf8.encode(jsonEncode(baseline)).length;
        // Missing-capture coverage repeats the Run-local invocation identity,
        // making final JSON larger than the individually budgeted query results.
        expect(documentBytes, greaterThan(storage.collectedBytes));
        final additional = sessionEvidenceMaxBytes - documentBytes + 1;
        for (var i = 0; i < 17; i++) {
          storage.rows[chatEntries.name]![i]['content'] =
              'x' * (1 + additional ~/ 17 + (i < additional % 17 ? 1 : 0));
        }
        storage.collectedBytes = 0;
        storage.finalHeaderQueries.clear();
        await _expectUnpublishedFailure(collector, 'collection_limit');
        expect(storage.collectedBytes, lessThan(sessionEvidenceMaxBytes));
        expect(
          storage.responseBytes,
          everyElement(lessThan(relationalQueryByteLimit)),
        );
        expect(storage.finalHeaderQueries, hasLength(1));
      },
    );

    for (final transition in [
      'append',
      'seal complete',
      'seal failed',
      'append and seal',
    ]) {
      test(
        'concurrent capturing $transition exports only the initial committed snapshot',
        () async {
          final header = storage.capture(
            output: [('stdout', 'initial')],
            overrides: {
              'state': 'capturing',
              'termination': null,
              'exit_code': null,
            },
          );
          final initial = Map<String, Object?>.of(header);
          storage.beforeQuery = (sql, parameters) {
            if (!sql.startsWith('select c.position')) return;
            storage.beforeQuery = null;
            header['version'] = (header['version'] as int) + 1;
            if (transition.startsWith('append')) {
              header['high_water'] = 2;
              header['total_code_units'] = 12;
              storage.rows[commandChunks.name]!.add({
                'run_id': 'run',
                'invocation_id': 'command',
                'position': 2,
                'stream': 'stderr',
                'text': 'later',
              });
            }
            if (transition != 'append') {
              header['state'] = transition == 'seal failed'
                  ? 'failed'
                  : 'complete';
              if (transition == 'seal failed') {
                header['failure'] = 'later failure';
              } else {
                header['termination'] = 'exited';
                header['exit_code'] = 0;
              }
            }
          };
          final document = await read();
          final capture = _captures(document).single;
          expect(capture['header'], initial);
          expect(capture['chunks'], [
            {'position': 1, 'stream': 'stdout', 'text': 'initial'},
          ]);
          expect(capture['completeness'], 'unsealed_liveness_unknown');
          expect(storage.chunkQueries.single[':high_water'], 1);
          expect(_commandCoverage(document)['status'], 'partial');
          expect(jsonEncode(capture), isNot(contains('later')));
        },
      );
    }

    for (final mutation in <String, void Function(_QueryFixture, _Row)>{
      'metadata program': (s, h) => h['program'] = 'changed',
      'metadata argv encoding': (s, h) => h['arguments_json'] = '["hello",""]',
      'metadata timeout': (s, h) => h['timeout_seconds'] = 31,
      'metadata Environment': (s, h) => h['environment_id'] = 'foreign',
      'version regression': (s, h) => h['version'] = 1,
      'version without append or seal': (s, h) => h['version'] = 10,
      'seal without version': (s, h) {
        h.addAll({
          'state': 'complete',
          'termination': 'exited',
          'exit_code': 0,
        });
      },
      'high-water regression': (s, h) {
        s.rows[commandChunks.name]!.clear();
        h.addAll({'version': 10, 'high_water': 0, 'total_code_units': 0});
      },
      'units change without append': (s, h) =>
          h.addAll({'version': 10, 'total_code_units': 8}),
      'append without version': (s, h) {
        h.addAll({'high_water': 2, 'total_code_units': 8});
        s.rows[commandChunks.name]!.add({
          ...s.rows[commandChunks.name]!.single,
          'position': 2,
          'text': 'x',
        });
      },
      'append claims too few additional units': (s, h) {
        h.addAll({'version': 10, 'high_water': 2, 'total_code_units': 7});
        s.rows[commandChunks.name]!.add({
          ...s.rows[commandChunks.name]!.single,
          'position': 2,
          'text': 'x',
        });
      },
      'append claims too many additional units': (s, h) {
        h.addAll({'version': 10, 'high_water': 2, 'total_code_units': 4104});
        s.rows[commandChunks.name]!.add({
          ...s.rows[commandChunks.name]!.single,
          'position': 2,
          'text': 'x',
        });
      },
      'extra chunks outside final extent': (s, h) => s.rows[commandChunks.name]!
          .add({...s.rows[commandChunks.name]!.single, 'position': 2}),
      'missing final chunks': (s, h) => s.rows[commandChunks.name]!.clear(),
      'header disappeared': (s, h) => s.rows[commandCaptures.name]!.clear(),
      'header duplicated': (s, h) =>
          s.rows[commandCaptures.name]!.add(Map.of(h)),
    }.entries) {
      test(
        'concurrent ${mutation.key} fails final validation atomically',
        () async {
          final header = storage.capture(
            output: [('stdout', 'initial')],
            overrides: {
              'state': 'capturing',
              'termination': null,
              'exit_code': null,
            },
          );
          storage.beforeQuery = (sql, parameters) {
            if (sql.contains('as chunk_count') &&
                parameters.containsKey(':run')) {
              mutation.value(storage, header);
            }
          };
          await _expectUnpublishedFailure(collector, 'malformed_data');
          expect(storage.chunkQueries, hasLength(1));
        },
      );
    }

    for (final state in ['complete', 'failed']) {
      test('sealed $state header cannot mutate or append', () async {
        final header = storage.capture(
          overrides: {
            'state': state,
            'failure': state == 'failed' ? 'failed' : null,
          },
        );
        storage.beforeQuery = (sql, parameters) {
          if (sql.contains('as chunk_count') &&
              parameters.containsKey(':run')) {
            header['version'] = (header['version'] as int) + 1;
          }
        };
        await _expectUnpublishedFailure(collector, 'malformed_data');
      });
    }

    for (final mutation in ['duplicate identity', 'discovery count changed']) {
      test(
        'command $mutation cannot publish a silently truncated discovery',
        () async {
          storage.capture();
          if (mutation == 'duplicate identity') {
            storage.capture();
          } else {
            storage.countOverrides[commandCaptures.name] = 2;
          }
          await _expectUnpublishedFailure(collector, 'malformed_data');
        },
      );
    }
  });
}

Matcher _failure(String code) =>
    isA<SessionEvidenceFailure>().having((e) => e.code, 'code', code);

_Row _nestedData(int containers, {Object? leaf = 0}) {
  Object? value = leaf;
  for (var i = 0; i < containers; i++) {
    value = <String, Object?>{'nested': value};
  }
  return value! as _Row;
}

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

List<_Row> _captures(_Row document) =>
    ((document['command_tools'] as _Row)['captures'] as List).cast<_Row>();

_Row _commandCoverage(_Row document) =>
    (document['coverage'] as _Row)['command_transcripts'] as _Row;

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
  void Function(String sql, _Row parameters)? beforeQuery;
  void Function(String sql, _Row parameters, List<_Row> rows)? afterSelect;
  final headerCursors = <(Object?, Object?)>[];
  final chunkQueries = <_Row>[];
  final finalHeaderQueries = <_Row>[];
  final responseBytes = <int>[];
  var returnedRows = 0;
  var collectedBytes = 0;

  void commandSchema() {
    versions[commandSchemaOwner] = [1];
    for (final table in [commandCaptures, commandChunks]) {
      columns[table.name] = [...table.columns];
      rows.putIfAbsent(table.name, () => []);
    }
  }

  _Row capture({
    String run = 'run',
    String invocation = 'command',
    String session = _session,
    List<(String, String)> output = const [],
    _Row overrides = const {},
  }) {
    commandSchema();
    final header = _row(commandCaptures, {
      'session_id': session,
      'run_id': run,
      'invocation_id': invocation,
      'environment_id': 'environment',
      'program': 'printf',
      'arguments_json': '[ "hello", "" ]',
      'working_directory': '',
      'timeout_seconds': 30,
      'state': 'complete',
      'version': output.length + 2,
      'high_water': output.length,
      'total_code_units': output.fold<int>(
        0,
        (n, chunk) => n + chunk.$2.length,
      ),
      'termination': 'exited',
      'exit_code': 0,
      ...overrides,
    });
    rows[commandCaptures.name]!.add(header);
    for (var i = 0; i < output.length; i++) {
      rows[commandChunks.name]!.add({
        'run_id': run,
        'invocation_id': invocation,
        'position': i + 1,
        'stream': output[i].$1,
        'text': output[i].$2,
      });
    }
    return header;
  }

  void commandRun({
    String run = 'run',
    String invocation = 'command',
    String execution = 'started',
    _Row? header,
  }) {
    addRun(run, latest: 10);
    rows[_models.name]!.add(_model(run, 'model', 1, 3));
    final arguments = jsonEncode({
      'program': header?['program'] ?? 'printf',
      'arguments': jsonDecode(
        header?['arguments_json'] as String? ?? '["hello", ""]',
      ),
      'workingDirectory': header?['working_directory'] ?? '',
      'timeoutSeconds': header?['timeout_seconds'] ?? 30,
    });
    rows[_outputs.name]!.add(
      _row(_outputs, {
        'run_id': run,
        'model_invocation_id': 'model',
        'sequence': 2,
        'kind': 'toolProposal',
        'provider_call_id': 'provider-call',
        'alias': 'run_command',
        'arguments_json': arguments,
      }),
    );
    rows[_tools.name]!.add(
      _row(_tools, {
        'run_id': run,
        'invocation_id': invocation,
        'model_invocation_id': 'model',
        'tool_id': commandToolId,
        'alias': 'run_command',
        'provider_call_id': 'provider-call',
        'canonical_arguments_json': arguments,
        'prepared_sequence': 4,
        'proposal_sequence': 2,
      }),
    );
    void change(int sequence, String kind, [_Row payload = const {}]) {
      rows[_changes.name]!.add(
        _row(_changes, {
          'run_id': run,
          'tool_invocation_id': invocation,
          'sequence': sequence,
          'kind': kind,
          ...payload,
        }),
      );
    }

    change(4, 'prepared');
    if (execution == 'prepared') return;
    change(5, 'policyEvaluated', {
      'policy_decision': execution == 'denied'
          ? 'deny'
          : execution == 'rejected'
          ? 'ask'
          : 'allow',
      'effects_json':
          '{"effects":["processExecution"],"targets":[],"summary":"Run command","uncertainty":"none"}',
    });
    if (execution == 'started') {
      change(6, 'executionStarted');
    } else if (execution == 'rejected') {
      change(6, 'approvalRequested', {
        'interruption_id': 'approval',
        'effects_json':
            '{"effects":["processExecution"],"targets":[],"summary":"Run command","uncertainty":"none"}',
      });
      change(7, 'approvalResolved', {
        'interruption_id': 'approval',
        'approved': 0,
      });
    }
    change(8, 'completed', {
      'outcome_disposition': execution == 'started'
          ? 'success'
          : execution == 'denied'
          ? 'policyDenied'
          : 'userRejected',
      'effect_certainty': execution == 'started'
          ? 'knownOccurred'
          : 'knownNotOccurred',
      'model_content': 'Bounded model result, not a transcript.',
      'host_data_json': '{}',
    });
  }

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
      RegExp(r'\blimit (1|2|32|128)$').hasMatch(normalized),
      'Every query must have a finite LIMIT: $sql',
    );
    if (failQuery?.call(normalized, parameters) ?? false) {
      throw StateError('Injected unavailable/retired storage.');
    }
    beforeQuery?.call(normalized, parameters);
    final result = _select(normalized, parameters);
    afterSelect?.call(normalized, parameters, result);
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
    responseBytes.add(bytes);
    returnedRows += result.length;
    collectedBytes += utf8.encode(jsonEncode(result)).length;
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
    if (sql.contains('from adele_command_captures h ')) {
      _require(
        sql.contains('where h.session_id = :session'),
        'Command headers must explicitly scope the requested Session.',
      );
      final scoped = rows[commandCaptures.name]!
          .where((row) => row['session_id'] == _session)
          .toList();
      if (sql.startsWith('select count(*) as row_count ')) {
        _require(
          parameters.length == 1 && sql.endsWith('limit 1'),
          'Invalid command capture count.',
        );
        return [
          {'row_count': countOverrides[commandCaptures.name] ?? scoped.length},
        ];
      }
      final projection = commandCaptures.columns.map((c) => 'h.$c').join(', ');
      _require(
        sql.startsWith('select $projection, ') &&
            ['count(*)', 'min(position)', 'max(position)'].every(
              (aggregate) => sql.contains(
                '(select $aggregate from adele_command_chunks c '
                'where c.run_id = h.run_id and c.invocation_id = h.invocation_id)',
              ),
            ),
        'Headers require exact columns and atomic correlated COUNT/MIN/MAX.',
      );
      Iterable<_Row> selected;
      if (sql.endsWith('order by h.invocation_id, h.run_id limit 1')) {
        final afterInvocation = parameters[':after_invocation'] as String?;
        final afterRun = parameters[':after_run'] as String?;
        _require(
          afterInvocation == null
              ? parameters.length == 1 &&
                    sql.endsWith(
                      'where h.session_id = :session '
                      'order by h.invocation_id, h.run_id limit 1',
                    )
              : afterRun != null &&
                    parameters.length == 3 &&
                    sql.endsWith(
                      'where h.session_id = :session '
                      'and (h.invocation_id, h.run_id) > (:after_invocation, :after_run) '
                      'order by h.invocation_id, h.run_id limit 1',
                    ),
          'Command discovery requires separate initial and indexed exclusive successor pages.',
        );
        headerCursors.add((afterInvocation, afterRun));
        scoped.sort((a, b) {
          final invocation = (a['invocation_id'] as String).compareTo(
            b['invocation_id'] as String,
          );
          return invocation != 0
              ? invocation
              : (a['run_id'] as String).compareTo(b['run_id'] as String);
        });
        selected = scoped
            .where(
              (row) =>
                  afterInvocation == null ||
                  (row['invocation_id'] as String).compareTo(afterInvocation) >
                      0 ||
                  (row['invocation_id'] == afterInvocation &&
                      (row['run_id'] as String).compareTo(afterRun!) > 0),
            )
            .take(1);
      } else {
        _require(
          sql.endsWith(
                'and h.run_id = :run and h.invocation_id = :invocation limit 2',
              ) &&
              parameters.length == 3,
          'Final header validation requires exact Run/invocation and LIMIT 2.',
        );
        finalHeaderQueries.add(Map.of(parameters));
        selected = scoped
            .where(
              (row) =>
                  row['run_id'] == parameters[':run'] &&
                  row['invocation_id'] == parameters[':invocation'],
            )
            .take(2);
      }
      return [for (final row in selected) _commandHeader(row)];
    }
    if (sql.contains('from adele_command_chunks c ')) {
      _require(
        sql ==
            'select c.position, c.stream, c.text from adele_command_chunks c '
                'join adele_command_captures h '
                'on h.run_id = c.run_id and h.invocation_id = c.invocation_id '
                'where h.session_id = :session and h.run_id = :run '
                'and h.invocation_id = :invocation and c.position > :after '
                'and c.position <= :high_water order by c.position limit 32',
        'Chunks require Session header JOIN, exact identity and bounded initial high-water.',
      );
      chunkQueries.add(Map.of(parameters));
      final scoped = <_Row>[];
      for (final chunk in rows[commandChunks.name]!) {
        for (final header in rows[commandCaptures.name]!) {
          if (header['session_id'] == _session &&
              header['run_id'] == parameters[':run'] &&
              header['invocation_id'] == parameters[':invocation'] &&
              chunk['run_id'] == header['run_id'] &&
              chunk['invocation_id'] == header['invocation_id'] &&
              (chunk['position'] as int) > (parameters[':after'] as int) &&
              (chunk['position'] as int) <=
                  (parameters[':high_water'] as int)) {
            scoped.add(chunk);
          }
        }
      }
      scoped.sort(
        (a, b) => (a['position'] as int).compareTo(b['position'] as int),
      );
      return [
        for (final row in scoped.take(32))
          {
            for (final field in ['position', 'stream', 'text'])
              field: row[field],
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

  _Row _commandHeader(_Row header) {
    final positions =
        rows[commandChunks.name]!
            .where(
              (chunk) =>
                  chunk['run_id'] == header['run_id'] &&
                  chunk['invocation_id'] == header['invocation_id'],
            )
            .map((chunk) => chunk['position'] as int)
            .toList()
          ..sort();
    return {
      for (final field in commandCaptures.columns) field: header[field],
      'chunk_count': positions.length,
      'first_position': positions.isEmpty ? null : positions.first,
      'last_position': positions.isEmpty ? null : positions.last,
    };
  }
}
