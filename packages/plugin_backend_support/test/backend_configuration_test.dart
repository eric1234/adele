import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:test/test.dart';

void main() {
  late List<Map<String, Object?>> sent;
  late AdeleHostRequestMultiplexer host;
  late AdeleConfigurationClient client;

  setUp(() {
    sent = [];
    host = AdeleHostRequestMultiplexer(send: sent.add);
    client = AdeleConfigurationClient(
      hostRequests: host,
      hostInfrastructureContext: 'captured-generation',
    );
  });
  tearDown(() => host.close());

  void reply(Object? payload) => host.handleResponse({
    'kind': 'hostResponse',
    'requestId': sent.last['requestId'],
    'ok': true,
    'payload': payload,
  });

  test(
    'binds the exact service and context with a fresh empty request',
    () async {
      expect(backendConfigurationServiceId, 'adele.configuration');
      expect(sent, isEmpty);
      final result = client.currentRecords();
      expect(sent.single, {
        'kind': 'hostRequest',
        'requestId': 0,
        'hostContextKind': 'infrastructure',
        'hostContext': 'captured-generation',
        'serviceId': backendConfigurationServiceId,
        'method': 'currentRecords',
        'payload': <String, Object?>{},
      });
      reply({'records': <Object?>[], 'isComplete': true});
      final observation = await result;
      expect(observation.records, isEmpty);
      expect(observation.isComplete, isTrue);

      // The outgoing payload must be a fresh plain map, not an immutable wrapper.
      final firstPayload = sent.single['payload'] as Map<String, Object?>;
      firstPayload['owner'] = 'not-a-selector';
      final next = client.currentRecords();
      expect(sent.last['requestId'], 1);
      expect(sent.last['payload'], <String, Object?>{});
      expect(identical(sent.last['payload'], firstPayload), isFalse);
      reply({'records': <Object?>[], 'isComplete': false});
      final partial = await next;
      expect(partial.records, isEmpty);
      expect(partial.isComplete, isFalse);
    },
  );

  test(
    'observations copy deeply and remain independent of later reads',
    () async {
      final values = <String, Object?>{
        'enabled': false,
        'count': 0,
        'name': '',
        'wide-integer': 9007199254740993,
      };
      final record = _record(values: values);
      final records = [record];
      final expected = [_record(values: Map<String, Object?>.of(values))];
      final local = AdeleRecordObservation(records: records, isComplete: false);
      final pending = client.currentRecords();
      final payload = <String, Object?>{
        'records': records,
        'isComplete': false,
      };
      reply(payload);
      values.clear();
      record['id'] = 'changed';
      records.clear();
      payload['isComplete'] = true;
      payload.clear();
      final remote = await pending;

      final next = client.currentRecords();
      reply({
        'records': [_record(id: 'personal')],
        'isComplete': true,
      });
      expect((await next).records.single['id'], 'personal');
      for (final observation in [local, remote]) {
        expect(observation.records, expected);
        expect(observation.isComplete, isFalse);
        expect(observation.records.clear, throwsUnsupportedError);
        expect(
          () => observation.records.add(_record().cast<String, Object>()),
          throwsUnsupportedError,
        );
        expect(observation.records.single.clear, throwsUnsupportedError);
        expect(
          () => observation.records.single['id'] = 'replacement',
          throwsUnsupportedError,
        );
        final fields =
            observation.records.single['values'] as Map<String, Object>;
        expect(fields.clear, throwsUnsupportedError);
        expect(() => fields['count'] = 1, throwsUnsupportedError);
      }
    },
  );

  test('exposes no selector, mutation or credential operations', () {
    for (final selector in [
      #collection,
      #recordType,
      #recordId,
      #slot,
      #owner,
      #generation,
      #configurationContext,
      #serviceId,
    ]) {
      expect(
        () => Function.apply(client.currentRecords, [], {selector: 'private'}),
        throwsNoSuchMethodError,
      );
    }
    final dynamic readOnly = client;
    for (final invoke in <void Function()>[
      () => readOnly.createRecord(),
      () => readOnly.updateRecord(),
      () => readOnly.deleteRecord(),
      () => readOnly.readCredential(),
      () => readOnly.writeCredential(),
      () => readOnly.request('anything', <String, Object?>{}),
    ]) {
      expect(invoke, throwsNoSuchMethodError);
    }
    expect(sent, isEmpty);
  });

  test(
    'failures expose only the fixed kind, never payloads or native causes',
    () {
      for (final kind in AdeleConfigurationFailureKind.values) {
        final failure = AdeleConfigurationFailure(kind);
        expect(failure, _failure(kind));
        expect(() => (failure as dynamic).cause, throwsNoSuchMethodError);
        expect(() => (failure as dynamic).payload, throwsNoSuchMethodError);
        expect(() => (failure as dynamic).details, throwsNoSuchMethodError);
        expect(() => (failure as dynamic).message, throwsNoSuchMethodError);
      }
    },
  );

  for (final kind in AdeleConfigurationFailureKind.values) {
    test(
      'fixed semantic failure ${kind.name} is captured before await',
      () async {
        final result = client.currentRecords();
        final check = expectLater(result, throwsA(_failure(kind)));
        final payload = <String, Object?>{'failure': kind.name};
        reply(payload);
        payload.clear();
        await check;
      },
    );
  }

  const marker = 'private-payload-or-native-error-do-not-echo';
  final malformed = <Object?>[
    null,
    marker,
    [],
    {},
    {'records': <Object?>[]},
    {'isComplete': true},
    {'records': null, 'isComplete': true},
    {'records': <String, Object?>{}, 'isComplete': true},
    {'records': marker, 'isComplete': true},
    {'records': <Object?>[], 'isComplete': null},
    {'records': <Object?>[], 'isComplete': 'true'},
    {'records': <Object?>[], 'isComplete': 1},
    {'records': <Object?>[], 'isComplete': true, 'extra': marker},
    {'records': <Object?>[], 'isComplete': false, 'failure': 'notAuthorized'},
    {'failure': marker},
    {'failure': null},
    {'failure': 0},
    {'failure': AdeleConfigurationFailureKind.notAuthorized},
    {'failure': 'notAuthorized', 'message': marker},
    {'records': <Object?>[], 'failure': 'notAuthorized'},
    {'isComplete': true, 'failure': 'notAuthorized'},
    {1: marker},
    {'records': Object(), 'isComplete': true},
  ];
  for (var i = 0; i < malformed.length; i++) {
    test('malformed response $i is a redacted access failure', () async {
      final result = client.currentRecords();
      final check = expectLater(
        result,
        throwsA(
          _failure(AdeleConfigurationFailureKind.configurationAccessFailed),
        ),
      );
      reply(malformed[i]);
      await check;
    });
  }

  test(
    'local and wire observations enforce the existing record grammar',
    () async {
      final malformedRecords = <List<Map<String, Object?>>>[
        [_record()..remove('values')],
        [for (var i = 0; i < 2; i++) _record()],
        [_record(id: '../$marker')],
        [_record(id: 'con')],
        [_record(type: 'not-public')],
        [
          for (final field in [
            'credentials',
            'references',
            'root',
            'authorization',
          ])
            {..._record(id: field), field: marker},
        ],
        for (final value in <Object?>[null, 0.0, [], {}, Object()])
          [
            _record(values: {'field': value}),
          ],
        [
          _record(values: {'invalid/field': marker}),
        ],
        [
          _record(values: {1: marker}),
        ],
      ];
      for (final records in malformedRecords) {
        expect(
          () => AdeleRecordObservation(records: records, isComplete: true),
          throwsA(
            isA<FormatException>()
                .having((failure) => failure.source, 'source', isNull)
                .having(
                  (failure) => failure.toString(),
                  'redacted message',
                  isNot(contains(marker)),
                ),
          ),
        );
        final result = client.currentRecords();
        final check = expectLater(
          result,
          throwsA(
            _failure(AdeleConfigurationFailureKind.configurationAccessFailed),
          ),
        );
        reply({'records': records, 'isComplete': true});
        await check;
      }
      for (final entry in <Object?>[null, marker, 1, []]) {
        final result = client.currentRecords();
        final check = expectLater(
          result,
          throwsA(
            _failure(AdeleConfigurationFailureKind.configurationAccessFailed),
          ),
        );
        reply({
          'records': [entry],
          'isComplete': true,
        });
        await check;
      }
    },
  );

  test(
    'local and wire observations reject excessive records, fields and size',
    () async {
      for (final records in [
        [
          for (var i = 0; i <= AdeleBackendRecords.maxRecords; i++)
            _record(id: 'record-$i'),
        ],
        [
          _record(
            values: {
              for (var i = 0; i <= AdeleBackendRecords.maxFields; i++)
                'field-$i': true,
            },
          ),
        ],
        [
          _record(
            values: {'text': 'x' * (AdeleBackendRecords.maxStringLength + 1)},
          ),
        ],
        [
          _record(
            values: {
              for (var i = 0; i < 16; i++)
                'field-$i': 'x' * AdeleBackendRecords.maxStringLength,
            },
          ),
        ],
      ]) {
        expect(
          () => AdeleRecordObservation(records: records, isComplete: true),
          throwsFormatException,
        );
        final result = client.currentRecords();
        final check = expectLater(
          result,
          throwsA(
            _failure(AdeleConfigurationFailureKind.configurationAccessFailed),
          ),
        );
        reply({'records': records, 'isComplete': true});
        await check;
      }
    },
  );

  test('only recognized transport codes map to authority failures', () async {
    for (final entry in {
      'host_infrastructure_unavailable':
          AdeleConfigurationFailureKind.generationUnavailable,
      'host_invocation_unavailable':
          AdeleConfigurationFailureKind.generationUnavailable,
      'service_unavailable': AdeleConfigurationFailureKind.notAuthorized,
      'configurationUnavailable':
          AdeleConfigurationFailureKind.configurationAccessFailed,
      marker: AdeleConfigurationFailureKind.configurationAccessFailed,
    }.entries) {
      final result = client.currentRecords();
      final check = expectLater(result, throwsA(_failure(entry.value)));
      host.handleResponse({
        'kind': 'hostResponse',
        'requestId': sent.last['requestId'],
        'ok': false,
        'error': {
          'code': entry.key,
          'message': marker,
          'details': {'private': marker},
        },
      });
      await check;
    }
  });

  test('malformed transport envelopes cannot publish observations', () async {
    final payload = <String, Object?>{
      'records': [
        _record(values: {'private': marker}),
      ],
      'isComplete': true,
    };
    for (final fields in <Map<String, Object?>>[
      {'ok': true, 'payload': payload, 'extra': marker},
      {'ok': true, 'result': payload},
      {'ok': marker, 'payload': payload},
      {'ok': false, 'error': marker},
      {
        'ok': false,
        'error': {
          'code': 'service_unavailable',
          'message': marker,
          'details': [marker],
        },
      },
    ]) {
      final result = client.currentRecords();
      final check = expectLater(
        result,
        throwsA(
          _failure(AdeleConfigurationFailureKind.configurationAccessFailed),
        ),
      );
      host.handleResponse({
        'kind': 'hostResponse',
        'requestId': sent.last['requestId'],
        ...fields,
      });
      await check;
    }
  });

  test('transport throws and closure retain no underlying cause', () async {
    final pending = client.currentRecords();
    final check = expectLater(
      pending,
      throwsA(
        _failure(AdeleConfigurationFailureKind.configurationAccessFailed),
      ),
    );
    host.close();
    await check;
    await expectLater(
      client.currentRecords(),
      throwsA(
        _failure(AdeleConfigurationFailureKind.configurationAccessFailed),
      ),
    );
    host = AdeleHostRequestMultiplexer(send: (_) => throw StateError(marker));
    client = AdeleConfigurationClient(
      hostRequests: host,
      hostInfrastructureContext: 'another-generation',
    );
    await expectLater(
      client.currentRecords(),
      throwsA(
        _failure(AdeleConfigurationFailureKind.configurationAccessFailed),
      ),
    );
  });
}

Map<String, Object?> _record({
  String id = 'work',
  String type = 'dev.adele.fixture.provider',
  Object? values = const <String, Object>{},
}) => {'collection': 'providers', 'type': type, 'id': id, 'values': values};

Matcher _failure(AdeleConfigurationFailureKind kind) =>
    isA<AdeleConfigurationFailure>()
        .having((failure) => failure.kind, 'kind', kind)
        .having(
          (failure) => failure.toString(),
          'fixed redacted diagnostic',
          'Configuration access failed (${kind.name}).',
        );
