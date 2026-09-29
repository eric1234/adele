import 'dart:convert';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:test/test.dart';

void main() {
  test('named parameters and rows retain only strings, integers, and null', () {
    final source = <String, Object?>{
      ':text': 'exact',
      ':integer': 7,
      ':null': null,
    };
    final statement = RelationalStatement(
      sql: 'SELECT :text, :integer, :null',
      parameters: source,
      expectedRows: null,
    );
    source[':text'] = 'changed';
    expect(statement.parameters[':text'], 'exact');
    expect(() => statement.parameters[':new'] = 1, throwsUnsupportedError);
    final row = RelationalRow(
      values: {'text': 'exact', 'integer': 7, 'nil': null},
    );
    expect(() => row.values['text'] = 'changed', throwsUnsupportedError);
    for (final invalid in <Object>[true, 1.5, <Object>[], <String, Object>{}]) {
      expect(
        () => RelationalStatement(
          sql: 'SELECT :value',
          parameters: {':value': invalid},
          expectedRows: null,
        ),
        throwsFormatException,
      );
      expect(
        () => RelationalRow(values: {'value': invalid}),
        throwsFormatException,
      );
    }
    expect(
      () =>
          RelationalStatement(sql: 'DELETE', parameters: {}, expectedRows: -1),
      throwsArgumentError,
    );
  });

  test(
    'generated service transports relational data without owner or path',
    () async {
      final service = _Storage();
      final dispatcher = ProjectStorageServiceDispatcher(service);
      addTearDown(dispatcher.close);
      final channel = _Channel(dispatcher);
      final client = ProjectStorageServiceClient(channel);
      expect(await client.isDurableSession('session'), isTrue);
      await client.ensureSchemaForSession('session', [
        'CREATE TABLE owned (id TEXT)',
      ], ProjectStorageAccessMode.durable);
      expect(service.migrations, ['CREATE TABLE owned (id TEXT)']);
      expect(service.accessMode, ProjectStorageAccessMode.durable);
      await client.transactionForSession('session', [
        RelationalStatement(
          sql: 'INSERT INTO owned VALUES (:id)',
          parameters: {':id': 'entry'},
          expectedRows: 1,
        ),
      ], ProjectStorageAccessMode.durableOrTemporary);
      expect(service.statements.single.parameters, {':id': 'entry'});
      expect(service.statements.single.expectedRows, 1);
      expect(service.accessMode, ProjectStorageAccessMode.durableOrTemporary);
      final rows = await client.queryForSession('session', 'SELECT :value', {
        ':value': 3,
      }, ProjectStorageAccessMode.durableOrTemporary);
      expect(service.accessMode, ProjectStorageAccessMode.durableOrTemporary);
      expect(rows.single.values, {
        'text': 'retained',
        'integer': 3,
        'nil': null,
      });
      for (final payload in channel.payloads) {
        expect(payload['sessionId'], 'session');
        expect(payload.keys, isNot(contains('ownerId')));
        expect(payload.keys, isNot(contains('path')));
      }
      expect(channel.payloads.skip(1).map((payload) => payload['accessMode']), [
        'durable',
        'durableOrTemporary',
        'durableOrTemporary',
      ]);
    },
  );

  test(
    'generated transport rejects unsupported values before service use',
    () async {
      final dispatcher = ProjectStorageServiceDispatcher(_Storage());
      addTearDown(dispatcher.close);
      final response = await dispatcher.dispatch({
        'kind': 'request',
        'requestId': 1,
        'method': projectStorageServiceTransactionForSessionId,
        'payload': {
          'sessionId': 'session',
          'accessMode': 'durable',
          'statements': [
            {
              'sql': 'INSERT',
              'parameters': {':value': true},
              'expectedRows': null,
            },
          ],
        },
      });
      expect(response['ok'], isFalse);
    },
  );

  test('requests cannot choose a different schema owner', () async {
    final service = _Storage();
    final dispatcher = ProjectStorageServiceDispatcher(service);
    addTearDown(dispatcher.close);
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': 1,
      'method': projectStorageServiceEnsureSchemaForSessionId,
      'payload': {
        'sessionId': 'session',
        'accessMode': 'durable',
        'migrations': ['CREATE TABLE forbidden (id TEXT)'],
        'ownerId': 'dev.some.other.plugin',
      },
    });
    expect(response['ok'], isFalse);
    expect((response['error']! as Map)['code'], 'invalid_request');
    expect(service.migrations, isEmpty);
  });

  test(
    'access mode is explicit and unknown modes fail before service use',
    () async {
      final service = _Storage();
      final dispatcher = ProjectStorageServiceDispatcher(service);
      addTearDown(dispatcher.close);
      for (final extra in <Map<String, Object?>>[
        {},
        {'accessMode': null},
        {'accessMode': 'memory'},
        {'accessMode': 1},
      ]) {
        final response = await dispatcher.dispatch({
          'kind': 'request',
          'requestId': 1,
          'method': projectStorageServiceEnsureSchemaForSessionId,
          'payload': {
            'sessionId': 'session',
            'migrations': ['CREATE TABLE owned (id TEXT)'],
            ...extra,
          },
        });
        expect(response['ok'], isFalse);
        expect((response['error']! as Map)['code'], 'invalid_request');
      }
      expect(service.migrations, isEmpty);
      expect(service.accessMode, isNull);
    },
  );
}

final class _Storage implements ProjectStorageService {
  List<String> migrations = [];
  List<RelationalStatement> statements = [];
  ProjectStorageAccessMode? accessMode;

  @override
  Future<bool> isDurableSession(String sessionId) async => true;

  @override
  Future<void> ensureSchemaForSession(
    String sessionId,
    List<String> migrations,
    ProjectStorageAccessMode accessMode,
  ) async {
    this.migrations = migrations;
    this.accessMode = accessMode;
  }

  @override
  Future<List<RelationalRow>> queryForSession(
    String sessionId,
    String sql,
    Map<String, Object?> parameters,
    ProjectStorageAccessMode accessMode,
  ) async {
    this.accessMode = accessMode;
    return [
      RelationalRow(
        values: {
          'text': 'retained',
          'integer': parameters[':value'],
          'nil': null,
        },
      ),
    ];
  }

  @override
  Future<void> transactionForSession(
    String sessionId,
    List<RelationalStatement> statements,
    ProjectStorageAccessMode accessMode,
  ) async {
    this.statements = statements;
    this.accessMode = accessMode;
  }
}

final class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
  final List<Map<String, Object?>> payloads = [];

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    payloads.add(payload);
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': payloads.length,
      'method': method,
      'payload': jsonDecode(jsonEncode(payload)),
    });
    expect(response['ok'], isTrue);
    return jsonDecode(jsonEncode(response['payload']));
  }
}
