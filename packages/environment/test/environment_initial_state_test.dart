import 'dart:convert' as convert;

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:test/test.dart';

void main() {
  test('provider-state-only construction remains valid and immutable', () {
    final state = <String, Object?>{
      'nested': <String, Object?>{'value': 1},
    };
    final result = EnvironmentProviderResult(providerState: state);
    (state['nested']! as Map)['value'] = 2;
    expect(result.initialState, isNull);
    expect(result.providerState, {
      'nested': {'value': 1},
    });
    expect(() => result.providerState.clear(), throwsUnsupportedError);
    expect(
      () => (result.providerState['nested']! as Map).clear(),
      throwsUnsupportedError,
    );
  });

  test(
    'initial state snapshots collections and reuses relational statements',
    () {
      final parameters = <String, Object?>{
        ':value': 'initial',
        '@count': 7,
        r'$_nullable': null,
      };
      final insert = _insert(parameters: parameters);
      final inserts = [insert];
      final state = EnvironmentInitialState(schema: _schema, inserts: inserts);
      parameters.clear();
      inserts.clear();
      expect(state.inserts.single, same(insert));
      expect(insert.parameters, {
        ':value': 'initial',
        '@count': 7,
        r'$_nullable': null,
      });
      expect(() => state.inserts.clear(), throwsUnsupportedError);
      expect(() => insert.parameters.clear(), throwsUnsupportedError);
      final RelationalStatement statement = insert.toRelationalStatement();
      expect(statement.sql, insert.sql);
      expect(statement.parameters, insert.parameters);
      expect(statement.expectedRows, 1);
      expect(() => statement.parameters.clear(), throwsUnsupportedError);
    },
  );

  test(
    'initial inserts require bounded SQL and positive expected row counts',
    () {
      expect(environmentInitialSqlLimit, 16 * 1024);
      expect(environmentInitialExpectedRowsLimit, 1000);
      for (final sql in ['', ' \n\t', 'x' * (environmentInitialSqlLimit + 1)]) {
        expect(() => _insert(sql: sql), throwsFormatException);
      }
      for (final sql in [
        'x',
        'x' * environmentInitialSqlLimit,
        '\u{1f642}' * (environmentInitialSqlLimit ~/ 2),
      ]) {
        expect(_insert(sql: sql).sql, sql);
      }
      expect(
        () =>
            _insert(sql: '${'\u{1f642}' * (environmentInitialSqlLimit ~/ 2)}x'),
        throwsFormatException,
      );
      for (final expectedRows in [
        -1,
        0,
        environmentInitialExpectedRowsLimit + 1,
      ]) {
        expect(
          () => _insert(expectedRows: expectedRows),
          throwsFormatException,
        );
      }
      for (final expectedRows in [1, environmentInitialExpectedRowsLimit]) {
        expect(_insert(expectedRows: expectedRows).expectedRows, expectedRows);
      }
    },
  );

  test('initial parameters require bounded named SQLite scalar values', () {
    expect(environmentInitialParameterLimit, 64);
    for (final count in [0, environmentInitialParameterLimit]) {
      final parameters = <String, Object?>{
        for (int index = 0; index < count; index++) ':p$index': index,
      };
      expect(_insert(parameters: parameters).parameters, parameters);
    }
    expect(
      () => _insert(
        parameters: {
          for (
            int index = 0;
            index <= environmentInitialParameterLimit;
            index++
          )
            ':p$index': index,
        },
      ),
      throwsFormatException,
    );
    for (final name in [':a', '@A_1', r'$value', ':_']) {
      expect(_insert(parameters: {name: null}).parameters, {name: null});
    }
    for (final name in [
      '',
      'value',
      '?',
      '?1',
      ':',
      '@',
      r'$',
      ':1',
      ':a-b',
      ':a.b',
      ':a b',
      ':a\n',
      ' :a',
      ':a\x00',
      ':\u00e9',
      '::a',
      r'$a::b',
    ]) {
      expect(
        () => _insert(parameters: {name: null}),
        throwsFormatException,
        reason: name,
      );
    }
    for (final value in <Object?>[
      true,
      1.5,
      double.nan,
      <Object?>[],
      {},
      Object(),
    ]) {
      expect(
        () => _insert(parameters: {':value': value}),
        throwsFormatException,
        reason: '$value',
      );
    }
    for (final value in <Object?>['', 'text\n\x00', -7, 0, null]) {
      expect(
        _insert(parameters: {':value': value}).parameters[':value'],
        value,
      );
    }
  });

  test('initial state requires inserts and bounds optional schema text', () {
    expect(environmentInitialInsertLimit, 32);
    expect(environmentInitialSchemaLimit, 64 * 1024);
    for (final count in [0, environmentInitialInsertLimit + 1]) {
      expect(
        () => EnvironmentInitialState(
          schema: null,
          inserts: List.filled(count, _insert()),
        ),
        throwsFormatException,
      );
    }
    for (final count in [1, environmentInitialInsertLimit]) {
      expect(
        EnvironmentInitialState(
          schema: null,
          inserts: List.filled(count, _insert()),
        ).inserts.length,
        count,
      );
    }
    for (final schema in <String?>[
      null,
      'x',
      'x' * environmentInitialSchemaLimit,
      '\u{1f642}' * (environmentInitialSchemaLimit ~/ 2),
    ]) {
      expect(
        EnvironmentInitialState(schema: schema, inserts: [_insert()]).schema,
        schema,
      );
    }
    for (final schema in [
      '',
      ' \n\t',
      'x' * (environmentInitialSchemaLimit + 1),
      '${'\u{1f642}' * (environmentInitialSchemaLimit ~/ 2)}x',
    ]) {
      expect(
        () => EnvironmentInitialState(schema: schema, inserts: [_insert()]),
        throwsFormatException,
      );
    }
  });

  test('whole-plan bound counts UTF-8 bytes, JSON overhead and escapes', () {
    expect(environmentInitialStateByteLimit, 256 * 1024);
    final overhead = convert.utf8
        .encode(
          convert.jsonEncode({
            'schema': null,
            'inserts': [
              {
                ..._encodedInsert(),
                'parameters': {':value': ''},
              },
            ],
          }),
        )
        .length;
    for (final unit in ['x', '\u00e9', '\n', '\u{1f642}']) {
      final unitBytes =
          convert.utf8.encode(convert.jsonEncode(unit)).length - 2;
      final available = environmentInitialStateByteLimit - overhead;
      final value =
          unit * (available ~/ unitBytes) + 'x' * (available % unitBytes);
      final state = EnvironmentInitialState(
        schema: null,
        inserts: [
          _insert(parameters: {':value': value}),
        ],
      );
      expect(state.inserts.single.parameters[':value'], value);
      expect(
        () => EnvironmentInitialState(
          schema: null,
          inserts: [
            _insert(parameters: {':value': '${value}x'}),
          ],
        ),
        throwsFormatException,
      );
    }
    expect(
      () => EnvironmentInitialState(
        schema: 'x' * environmentInitialSchemaLimit,
        inserts: List.filled(
          environmentInitialInsertLimit,
          _insert(sql: 'x' * environmentInitialSqlLimit),
        ),
      ),
      throwsFormatException,
    );
  });

  group('generated initial-state transport', () {
    late _Provider provider;
    late EnvironmentProviderServiceAdapter adapter;
    late EnvironmentProviderServiceDispatcher dispatcher;
    late _Channel channel;
    late GeneratedEnvironmentProvider host;

    setUp(() {
      provider = _Provider();
      adapter = EnvironmentProviderServiceAdapter(provider);
      dispatcher = EnvironmentProviderServiceDispatcher(adapter);
      channel = _Channel(dispatcher);
      host = GeneratedEnvironmentProvider(
        providerId: provider.providerId,
        service: EnvironmentProviderServiceClient(channel),
      );
    });
    tearDown(() => dispatcher.close());

    test(
      'roundtrip preserves typed optional plans and immutable data',
      () async {
        for (final schema in <String?>[null, _schema]) {
          provider.result = EnvironmentProviderResult(
            providerState: const {'ready': true},
            initialState: EnvironmentInitialState(
              schema: schema,
              inserts: [_insert()],
            ),
          );
          final result = await host.establish(_localEnvironment());
          expect(provider.establishCalls, schema == null ? 1 : 2);
          expect(channel.method, environmentProviderServiceEstablishId);
          expect(channel.response!['payload'], {
            'providerState': {'ready': true},
            'initialState': {
              'schema': schema,
              'inserts': [_encodedInsert()],
            },
          });
          expect(result.providerState, {'ready': true});
          expect(
            result.initialState,
            isNot(same(provider.result.initialState)),
          );
          expect(result.initialState!.schema, schema);
          final insert = result.initialState!.inserts.single;
          expect(insert.sql, _sql);
          expect(insert.parameters, {':value': 'initial'});
          expect(insert.expectedRows, 1);
          expect(
            () => result.initialState!.inserts.clear(),
            throwsUnsupportedError,
          );
          expect(() => insert.parameters.clear(), throwsUnsupportedError);
        }
      },
    );

    test(
      'provider-state-only establish and restore carry explicit null',
      () async {
        for (final operation in [host.establish, host.restore]) {
          final result = await operation(_localEnvironment());
          expect(result.initialState, isNull);
          expect(channel.response!['payload'], {
            'providerState': {'ready': true},
            'initialState': null,
          });
        }
        expect(provider.establishCalls, 1);
        expect(provider.restoreCalls, 1);
      },
    );

    test(
      'service adapter rejects restore initialization as declared failure',
      () async {
        provider.result = EnvironmentProviderResult(
          providerState: const {'ready': true},
          initialState: EnvironmentInitialState(
            schema: _schema,
            inserts: [_insert()],
          ),
        );
        await expectLater(adapter.restore(_context()), _restoreFailure);
        await expectLater(host.restore(_localEnvironment()), _restoreFailure);
        expect(provider.restoreCalls, 2);
        expect(channel.response!['ok'], isFalse);
        expect(
          (channel.response!['error']! as Map)['declaredFailureType'],
          environmentFailureTypeId,
        );
      },
    );

    test(
      'generated provider rejects restore plans bypassing backend adapter',
      () async {
        final directHost = GeneratedEnvironmentProvider(
          providerId: provider.providerId,
          service: EnvironmentProviderServiceClient(
            _ResponseChannel(_encodedResult()),
          ),
        );
        await expectLater(
          directHost.restore(_localEnvironment()),
          _restoreFailure,
        );
        expect(provider.restoreCalls, 0);
      },
    );

    test(
      'client rejects malformed plans and forged ownership fields',
      () async {
        final insert = _encodedInsert();
        final state = _encodedState();
        final result = _encodedResult();
        final malformedInserts = <Object?>[
          null,
          [],
          for (final key in insert.keys) {...insert}..remove(key),
          for (final key in insert.keys) {...insert, key: null},
          {...insert, 'sql': 1},
          {...insert, 'sql': ''},
          {...insert, 'sql': 'x' * (environmentInitialSqlLimit + 1)},
          {...insert, 'expectedRows': 0},
          {...insert, 'expectedRows': 1001},
          {...insert, 'expectedRows': 1.5},
          {...insert, 'parameters': <Object?>[]},
          {
            ...insert,
            'parameters': {1: 'value'},
          },
          {
            ...insert,
            'parameters': {'value': 'missing prefix'},
          },
          for (final value in <Object?>[true, 1.5, <Object?>[], {}])
            {
              ...insert,
              'parameters': {':value': value},
            },
          {
            ...insert,
            'parameters': {
              for (
                int index = 0;
                index <= environmentInitialParameterLimit;
                index++
              )
                ':p$index': index,
            },
          },
        ];
        final malformedStates = <Object?>[
          [],
          'invalid',
          for (final key in state.keys) {...state}..remove(key),
          {...state, 'schema': 1},
          {...state, 'schema': ''},
          {...state, 'schema': 'x' * (environmentInitialSchemaLimit + 1)},
          {...state, 'inserts': null},
          {...state, 'inserts': <Object?>[]},
          {
            ...state,
            'inserts': List.filled(environmentInitialInsertLimit + 1, insert),
          },
          for (final invalid in malformedInserts)
            {
              ...state,
              'inserts': [invalid],
            },
          {
            ...state,
            'inserts': [
              {
                ...insert,
                'parameters': {
                  ':value': 'x' * environmentInitialStateByteLimit,
                },
              },
            ],
          },
        ];
        for (final payload in <Object?>[
          null,
          [],
          for (final key in result.keys) {...result}..remove(key),
          {...result, 'providerState': null},
          for (final invalid in malformedStates)
            {...result, 'initialState': invalid},
          for (final selector in [
            'owner',
            'pluginId',
            'projectId',
            'authority',
            'handle',
            'callback',
            'unknown',
          ]) ...[
            {...result, selector: 'forged'},
            {
              ...result,
              'initialState': {...state, selector: 'forged'},
            },
            {
              ...result,
              'initialState': {
                ...state,
                'inserts': [
                  {...insert, selector: 'forged'},
                ],
              },
            },
          ],
        ]) {
          await expectLater(
            EnvironmentProviderServiceClient(
              _ResponseChannel(payload),
            ).establish(_context()),
            throwsA(isA<AdeleProtocolException>()),
          );
        }
        expect(provider.establishCalls, 0);
      },
    );
  });
}

const _sql = 'INSERT INTO plugin_rows (value) VALUES (:value)';
const _schema = 'CREATE TABLE plugin_rows (value TEXT NOT NULL);';

EnvironmentInitialInsert _insert({
  String sql = _sql,
  Map<String, Object?> parameters = const {':value': 'initial'},
  int expectedRows = 1,
}) => EnvironmentInitialInsert(
  sql: sql,
  parameters: parameters,
  expectedRows: expectedRows,
);

Map<String, Object?> _encodedInsert() => {
  'sql': _sql,
  'parameters': {':value': 'initial'},
  'expectedRows': 1,
};

Map<String, Object?> _encodedState() => {
  'schema': _schema,
  'inserts': [_encodedInsert()],
};

Map<String, Object?> _encodedResult() => {
  'providerState': {'ready': true},
  'initialState': _encodedState(),
};

Matcher get _restoreFailure => throwsA(
  isA<EnvironmentFailure>().having(
    (error) => error.code,
    'code',
    'initial_state_on_restore',
  ),
);

EnvironmentTransportContext _context() => EnvironmentTransportContext(
  projectId: 'project-one',
  projectSourceLocation: Uri.parse('file:///tmp/project'),
  taskId: 'task-one',
  taskTitle: 'Task',
  environmentId: 'environment-one',
  environmentRole: 'primary',
  providerId: 'dev.adele.environment.fixture',
  providerStateInitialized: true,
  providerState: const {'ready': true},
);

LocalEnvironment _localEnvironment() => LocalEnvironment(
  project: Project(
    id: ProjectId('project-one'),
    sourceLocation: Uri.parse('file:///tmp/project'),
  ),
  task: Task(
    id: TaskId('task-one'),
    projectId: ProjectId('project-one'),
    title: 'Task',
  ),
  value: Environment(
    id: EnvironmentId('environment-one'),
    taskId: TaskId('task-one'),
    role: EnvironmentRole.primary,
    providerId: ProviderId('dev.adele.environment.fixture'),
    providerState: const {'ready': true},
  ),
);

final class _Provider implements EnvironmentProvider {
  @override
  ProviderId get providerId => ProviderId('dev.adele.environment.fixture');
  EnvironmentProviderResult result = EnvironmentProviderResult(
    providerState: const {'ready': true},
  );
  int establishCalls = 0;
  int restoreCalls = 0;

  @override
  Future<EnvironmentProviderResult> establish(
    LocalEnvironment environment,
  ) async {
    establishCalls++;
    return result;
  }

  @override
  Future<EnvironmentProviderResult> restore(
    LocalEnvironment environment,
  ) async {
    restoreCalls++;
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected provider operation.');
}

final class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
  String? method;
  Map<String, Object?>? response;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': 1,
      'method': method,
      'payload': payload,
    });
    this.response = response;
    if (response['ok'] != true) {
      throw _RemoteFailure(response['error']! as Map<Object?, Object?>);
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

final class _RemoteFailure implements AdeleRemoteFailure {
  _RemoteFailure(this.error);
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
