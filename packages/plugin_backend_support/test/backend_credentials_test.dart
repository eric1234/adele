import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:test/test.dart';

void main() {
  late List<Map<String, Object?>> sent;
  late AdeleHostRequestMultiplexer host;
  late AdeleCredentialClient client;

  setUp(() {
    sent = [];
    host = AdeleHostRequestMultiplexer(send: sent.add);
    client = AdeleCredentialClient(
      hostRequests: host,
      hostInfrastructureContext: 'captured-generation',
    );
  });
  tearDown(() => host.close());

  Future<String> read() => client.readCredential(
    collection: 'providers',
    recordType: 'dev.adele.fixture.provider',
    recordId: 'work',
    slot: 'api-key',
  );

  void reply(Object? payload) => host.handleResponse({
    'kind': 'hostResponse',
    'requestId': sent.last['requestId'],
    'ok': true,
    'payload': payload,
  });

  test(
    'binds existing infrastructure with only the four request selectors',
    () async {
      final result = read();
      expect(sent.single, {
        'kind': 'hostRequest',
        'requestId': 0,
        'hostContextKind': 'infrastructure',
        'hostContext': 'captured-generation',
        'serviceId': backendCredentialServiceId,
        'method': 'readCredential',
        'payload': {
          'collection': 'providers',
          'recordType': 'dev.adele.fixture.provider',
          'recordId': 'work',
          'slot': 'api-key',
        },
      });
      reply({'secret': 'value'});
      expect(await result, 'value');
      final firstPayload = sent.single['payload'] as Map;
      firstPayload.clear();
      final next = read();
      expect(sent.last['payload'], {
        'collection': 'providers',
        'recordType': 'dev.adele.fixture.provider',
        'recordId': 'work',
        'slot': 'api-key',
      });
      expect(identical(sent.last['payload'], firstPayload), isFalse);
      reply({'secret': 'next'});
      expect(await next, 'next');
    },
  );

  test(
    'captures response before callers can mutate it across the await',
    () async {
      final result = read();
      final payload = <String, Object?>{'secret': 'captured'};
      reply(payload);
      payload['secret'] = 'replacement';
      payload['failure'] = 'notAuthorized';
      expect(await result, 'captured');
      final failed = read();
      final check = expectLater(
        failed,
        throwsA(_failure(AdeleCredentialFailureKind.staleConfiguration)),
      );
      final error = <String, Object?>{'failure': 'staleConfiguration'};
      reply(error);
      error.clear();
      await check;
    },
  );

  for (final kind in AdeleCredentialFailureKind.values) {
    test('fixed semantic failure ${kind.name}', () async {
      final result = read();
      final check = expectLater(result, throwsA(_failure(kind)));
      reply({'failure': kind.name});
      await check;
    });
  }

  const marker = 'secret-or-native-error-do-not-echo';
  final malformed = <Object?>[
    null,
    marker,
    [],
    {},
    {'secret': null},
    {'secret': false},
    {'secret': 7},
    {
      'secret': [marker],
    },
    {'value': marker},
    {'failure': marker},
    {'failure': null},
    {
      'failure': {'code': marker},
    },
    {'secret': marker, 'failure': 'missingLocally'},
    {'secret': marker, 'extra': marker},
    {'failure': 'missingLocally', 'message': marker},
    {marker: marker},
    {1: marker},
    {'secret': Object()},
  ];
  for (var i = 0; i < malformed.length; i++) {
    test(
      'malformed semantic response $i is an opaque access failure',
      () async {
        final result = read();
        final check = expectLater(
          result,
          throwsA(_failure(AdeleCredentialFailureKind.credentialAccessFailed)),
        );
        reply(malformed[i]);
        await check;
      },
    );
  }

  test(
    'validates exact P1 secret bounds with SDK-only Unicode checks',
    () async {
      for (final value in [
        'a',
        ' ',
        'a' * 2560,
        '\u00e9' * 1280,
        '\u20ac' * 853,
        '\u{1f600}' * 640,
        '${'a' * 2556}\u{1f600}',
      ]) {
        final result = read();
        reply({'secret': value});
        expect(await result, value);
      }
      for (final value in [
        '',
        '\u0000',
        'before\u0000after',
        'a' * 2561,
        '\u00e9' * 1281,
        '\u20ac' * 854,
        '\u{1f600}' * 641,
        '\ud800',
        '\udfff',
        '\ud800x',
        '\ud800\ud800',
        '\udfff\ud800',
      ]) {
        final result = read();
        final check = expectLater(
          result,
          throwsA(_failure(AdeleCredentialFailureKind.credentialAccessFailed)),
        );
        reply({'secret': value});
        await check;
      }
    },
  );

  test(
    'only recognized transport codes get fixed authority failures',
    () async {
      for (final entry in {
        'host_infrastructure_unavailable':
            AdeleCredentialFailureKind.generationUnavailable,
        'host_invocation_unavailable':
            AdeleCredentialFailureKind.generationUnavailable,
        'service_unavailable': AdeleCredentialFailureKind.notAuthorized,
        marker: AdeleCredentialFailureKind.credentialAccessFailed,
      }.entries) {
        final result = read();
        final check = expectLater(result, throwsA(_failure(entry.value)));
        host.handleResponse({
          'kind': 'hostResponse',
          'requestId': sent.last['requestId'],
          'ok': false,
          'error': {
            'code': entry.key,
            'message': marker,
            'details': {'secret': marker},
          },
        });
        await check;
      }
    },
  );

  test(
    'malformed outer replies cannot publish a valid-looking secret',
    () async {
      for (final fields in <Map<String, Object?>>[
        {
          'ok': true,
          'payload': {'secret': marker},
          'extra': marker,
        },
        {
          'ok': true,
          'result': {'secret': marker},
        },
        {
          'ok': marker,
          'payload': {'secret': marker},
        },
        {'ok': false, 'error': marker},
        {
          'ok': false,
          'error': {
            'code': marker,
            'message': marker,
            'details': [marker],
          },
        },
      ]) {
        final result = read();
        final check = expectLater(
          result,
          throwsA(_failure(AdeleCredentialFailureKind.credentialAccessFailed)),
        );
        host.handleResponse({
          'kind': 'hostResponse',
          'requestId': sent.last['requestId'],
          ...fields,
        });
        await check;
      }
    },
  );

  test('transport throws and closure have no retained native cause', () async {
    host.close();
    await expectLater(
      read(),
      throwsA(_failure(AdeleCredentialFailureKind.credentialAccessFailed)),
    );
    host = AdeleHostRequestMultiplexer(send: (_) => throw StateError(marker));
    client = AdeleCredentialClient(
      hostRequests: host,
      hostInfrastructureContext: 'another-generation',
    );
    await expectLater(
      read(),
      throwsA(_failure(AdeleCredentialFailureKind.credentialAccessFailed)),
    );
  });
}

Matcher _failure(AdeleCredentialFailureKind kind) =>
    isA<AdeleCredentialFailure>()
        .having((failure) => failure.kind, 'kind', kind)
        .having(
          (failure) => failure.toString(),
          'bounded diagnostic',
          'Credential access failed (${kind.name}).',
        );
