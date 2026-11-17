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

  void reply(Object? payload, {Object? requestId}) => host.handleResponse({
    'kind': 'hostResponse',
    'requestId': requestId ?? sent.last['requestId'],
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

  group('live captures', () {
    const handle = '0123456789abcdef0123456789abcdef-0000000000000001';
    const nextHandle = '0123456789abcdef0123456789abcdef-0000000000000002';

    Map<String, Object?> response({
      String capture = handle,
      Object? records = const <Object?>[],
      bool isComplete = true,
    }) => {'capture': capture, 'records': records, 'isComplete': isComplete};

    Future<AdeleCredentialCapture> capture() {
      final pending = client.captureCurrentConfiguration();
      reply(response());
      return pending;
    }

    Future<String> readCaptured(AdeleCredentialCapture scope) =>
        scope.readCredential(
          collection: 'providers',
          recordType: 'dev.adele.fixture.provider',
          recordId: 'work',
          slot: 'api-key',
        );

    test('capture has an exact selector-free, fresh plain request', () async {
      final pending = client.captureCurrentConfiguration();
      expect(sent.single, {
        'kind': 'hostRequest',
        'requestId': 0,
        'hostContextKind': 'infrastructure',
        'hostContext': 'captured-generation',
        'serviceId': backendCredentialServiceId,
        'method': 'captureCurrentConfiguration',
        'payload': <String, Object?>{},
      });
      reply(response());
      final complete = await pending;
      expect(complete.records, isEmpty);
      expect(complete.isComplete, isTrue);

      final firstPayload = sent.single['payload'] as Map<String, Object?>;
      firstPayload['owner'] = marker;
      final next = client.captureCurrentConfiguration();
      expect(sent.last['payload'], <String, Object?>{});
      expect(identical(sent.last['payload'], firstPayload), isFalse);
      reply(response(capture: nextHandle, isComplete: false));
      final partial = await next;
      expect(partial.records, isEmpty);
      expect(partial.isComplete, isFalse);
      expect(complete.isComplete, isTrue);
    });

    test(
      'captures deeply immutable records before asynchronous publication',
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
        final payload = response(records: records, isComplete: false);
        final pending = client.captureCurrentConfiguration();
        reply(payload);
        values.clear();
        record['id'] = 'changed';
        records.clear();
        payload.clear();
        final scope = await pending;
        expect(scope.records, expected);
        expect(scope.isComplete, isFalse);
        expect(scope.records.clear, throwsUnsupportedError);
        expect(
          () => scope.records.add(_record().cast<String, Object>()),
          throwsUnsupportedError,
        );
        expect(scope.records.single.clear, throwsUnsupportedError);
        expect(
          () => scope.records.single['id'] = 'changed',
          throwsUnsupportedError,
        );
        final fields = scope.records.single['values'] as Map<String, Object>;
        expect(fields.clear, throwsUnsupportedError);
        expect(() => fields['count'] = 1, throwsUnsupportedError);

        expect((await capture()).records, isEmpty);
        final releasing = scope.release();
        reply({'released': true});
        await releasing;
        expect(scope.records, expected);
        expect(scope.isComplete, isFalse);
      },
    );

    test('captured reads use only their handle and four selectors', () async {
      final scope = await capture();
      final pending = readCaptured(scope);
      expect(sent.last, {
        'kind': 'hostRequest',
        'requestId': 1,
        'hostContextKind': 'infrastructure',
        'hostContext': 'captured-generation',
        'serviceId': backendCredentialServiceId,
        'method': 'readCapturedCredential',
        'payload': {
          'capture': handle,
          'collection': 'providers',
          'recordType': 'dev.adele.fixture.provider',
          'recordId': 'work',
          'slot': 'api-key',
        },
      });
      final payload = <String, Object?>{'secret': 'captured'};
      reply(payload);
      payload.clear();
      expect(await pending, 'captured');
      final firstPayload = sent.last['payload'] as Map<String, Object?>;
      final expected = Map<String, Object?>.of(firstPayload);
      firstPayload.clear();
      final next = readCaptured(scope);
      expect(sent.last['payload'], expected);
      expect(identical(sent.last['payload'], firstPayload), isFalse);
      reply({'secret': 'next'});
      expect(await next, 'next');
    });

    test('capture exposes neither handles nor caller-selected scope', () async {
      final scope = await capture();
      for (final selector in [
        #capture,
        #collection,
        #recordType,
        #recordId,
        #slot,
        #owner,
        #generation,
        #serviceId,
        #configurationContext,
      ]) {
        expect(
          () => Function.apply(client.captureCurrentConfiguration, [], {
            selector: marker,
          }),
          throwsNoSuchMethodError,
        );
      }
      final dynamic opaque = scope;
      for (final access in <void Function()>[
        () => opaque.handle,
        () => opaque.capture,
        () => opaque.channel,
        () => opaque.request('readCredential', <String, Object?>{}),
        () => opaque.writeCredential(),
        () => opaque.release(capture: handle),
      ]) {
        expect(access, throwsNoSuchMethodError);
      }
      expect(sent, hasLength(1));
    });

    test(
      'rejects malformed captures and nonpositive or malformed handles',
      () async {
        for (final payload in <Object?>[
          ...malformed,
          {'capture': handle, 'records': <Object?>[]},
          {'capture': handle, 'isComplete': true},
          {'records': <Object?>[], 'isComplete': true},
          {...response(), 'extra': marker},
          {...response(), 'failure': 'notAuthorized'},
          {...response(), 'isComplete': null},
          {...response(), 'isComplete': 1},
          {...response(), 'isComplete': 'true'},
          {...response(), 'records': null},
          {...response(), 'records': <String, Object?>{}},
          {...response(), 'records': marker},
          for (final invalid in <Object?>[
            null,
            1,
            {},
            '',
            marker,
            handle.toUpperCase(),
            '$handle\n',
            ' $handle',
            '${handle}0',
            handle.substring(1),
            handle.replaceFirst('-', '_'),
            handle.replaceFirst('0', 'g'),
            '${'a' * 32}-${'0' * 16}',
            '${'a' * 32}-${'0' * 15}G',
          ])
            {...response(), 'capture': invalid},
        ]) {
          final pending = client.captureCurrentConfiguration();
          final check = expectLater(
            pending,
            throwsA(
              _failure(AdeleCredentialFailureKind.credentialAccessFailed),
            ),
          );
          reply(payload);
          await check;
        }
      },
    );

    test('capture enforces record grammar and every transport bound', () async {
      for (final records in <Object?>[
        [null],
        [marker],
        [_record()..remove('values')],
        [_record(), _record()],
        [_record(id: '../$marker')],
        [_record(id: 'con')],
        [_record(id: 'a' * (AdeleBackendRecords.maxLocalIdLength + 1))],
        [_record()..['collection'] = 'aux'],
        [_record()..['type'] = 'not-public'],
        [
          _record()
            ..['type'] = 'a.${'a' * AdeleBackendRecords.maxTypeIdLength}',
        ],
        [_record()..['credentials'] = marker],
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
        final pending = client.captureCurrentConfiguration();
        final check = expectLater(
          pending,
          throwsA(_failure(AdeleCredentialFailureKind.credentialAccessFailed)),
        );
        reply(response(records: records));
        await check;
      }
    });

    test(
      'captured reads enforce existing response and secret grammar',
      () async {
        final scope = await capture();
        for (final payload in <Object?>[
          ...malformed,
          {'released': true},
          response(),
          for (final value in [
            '',
            'before\u0000after',
            'a' * 2561,
            '\u00e9' * 1281,
            '\u20ac' * 854,
            '\u{1f600}' * 641,
            '\ud800',
            '\udfff',
            '\ud800x',
          ])
            {'secret': value},
        ]) {
          final pending = readCaptured(scope);
          final check = expectLater(
            pending,
            throwsA(
              _failure(AdeleCredentialFailureKind.credentialAccessFailed),
            ),
          );
          reply(payload);
          await check;
        }
        for (final secret in [' ', 'a' * 2560, '\u{1f600}' * 640]) {
          final pending = readCaptured(scope);
          reply({'secret': secret});
          expect(await pending, secret);
        }
      },
    );

    test(
      'release strictly validates acknowledgement and never retries',
      () async {
        for (final payload in <Object?>[
          ...malformed,
          {'secret': 'valid-but-not-a-release'},
          response(),
          {'released': false},
          {'released': null},
          {'released': 1},
          {'released': 'true'},
          {'released': true, 'extra': marker},
          {'released': true, 'failure': 'staleConfiguration'},
        ]) {
          final scope = await capture();
          final pending = scope.release();
          final check = expectLater(
            pending,
            throwsA(
              _failure(AdeleCredentialFailureKind.credentialAccessFailed),
            ),
          );
          reply(payload);
          await check;
          final count = sent.length;
          expect(identical(scope.release(), pending), isTrue);
          await expectLater(
            readCaptured(scope),
            throwsA(_failure(AdeleCredentialFailureKind.staleConfiguration)),
          );
          expect(sent, hasLength(count));
        }
      },
    );

    for (final operation in ['capture', 'read', 'release']) {
      group(operation, () {
        late AdeleCredentialCapture scope;
        setUp(() async => scope = await capture());

        Future<Object?> request() => switch (operation) {
          'capture' => client.captureCurrentConfiguration(),
          'read' => readCaptured(scope),
          _ => scope.release(),
        };

        for (final kind in AdeleCredentialFailureKind.values) {
          test('preserves fixed ${kind.name} without retained data', () async {
            final pending = request();
            final check = expectLater(pending, throwsA(_failure(kind)));
            final payload = <String, Object?>{'failure': kind.name};
            reply(payload);
            payload.clear();
            await check;
          });
        }

        for (final entry in {
          'host_infrastructure_unavailable':
              AdeleCredentialFailureKind.generationUnavailable,
          'host_invocation_unavailable':
              AdeleCredentialFailureKind.generationUnavailable,
          'service_unavailable': AdeleCredentialFailureKind.notAuthorized,
          'staleConfiguration':
              AdeleCredentialFailureKind.credentialAccessFailed,
          marker: AdeleCredentialFailureKind.credentialAccessFailed,
        }.entries) {
          test('sanitizes transport failure ${entry.key}', () async {
            final pending = request();
            final check = expectLater(pending, throwsA(_failure(entry.value)));
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
          });
        }

        test('malformed outer responses cannot publish success', () async {
          final pending = request();
          final check = expectLater(
            pending,
            throwsA(
              _failure(AdeleCredentialFailureKind.credentialAccessFailed),
            ),
          );
          host.handleResponse({
            'kind': 'hostResponse',
            'requestId': sent.last['requestId'],
            'ok': true,
            'payload': switch (operation) {
              'capture' => response(),
              'read' => {'secret': marker},
              _ => {'released': true},
            },
            'extra': marker,
          });
          await check;
        });

        test('transport closure is an opaque failure', () async {
          final pending = request();
          final check = expectLater(
            pending,
            throwsA(
              _failure(AdeleCredentialFailureKind.credentialAccessFailed),
            ),
          );
          host.close();
          await check;
        });

        test('synchronous send exception is an opaque failure', () async {
          host.close();
          host = AdeleHostRequestMultiplexer(
            send: (message) {
              if (message['method'] != 'captureCurrentConfiguration' ||
                  operation == 'capture') {
                throw StateError(marker);
              }
              host.handleResponse({
                'kind': 'hostResponse',
                'requestId': message['requestId'],
                'ok': true,
                'payload': response(),
              });
            },
          );
          client = AdeleCredentialClient(
            hostRequests: host,
            hostInfrastructureContext: 'another-generation',
          );
          if (operation != 'capture') {
            scope = await client.captureCurrentConfiguration();
          }
          await expectLater(
            request(),
            throwsA(
              _failure(AdeleCredentialFailureKind.credentialAccessFailed),
            ),
          );
        });
      });
    }

    for (final replyBeforeRelease in [false, true]) {
      test(
        'release fences pending publication with early reply=$replyBeforeRelease',
        () async {
          final scope = await capture();
          final pending = readCaptured(scope);
          final readId = sent.last['requestId'];
          final check = expectLater(
            pending,
            throwsA(_failure(AdeleCredentialFailureKind.staleConfiguration)),
          );
          if (replyBeforeRelease) reply({'secret': marker}, requestId: readId);
          final releasing = scope.release();
          expect(identical(scope.release(), releasing), isTrue);
          expect(sent.last['method'], 'releaseCapture');
          expect(sent.last['payload'], {'capture': handle});
          final releaseId = sent.last['requestId'];
          await expectLater(
            readCaptured(scope),
            throwsA(_failure(AdeleCredentialFailureKind.staleConfiguration)),
          );
          expect(sent, hasLength(3));
          if (!replyBeforeRelease) reply({'secret': marker}, requestId: readId);
          await check;
          final payload = <String, Object?>{'released': true};
          reply(payload, requestId: releaseId);
          payload.clear();
          await releasing;
          expect(identical(scope.release(), releasing), isTrue);
          expect(sent, hasLength(3));
        },
      );
    }

    test(
      'release joins even during a synchronous transport callback',
      () async {
        host.close();
        late AdeleCredentialCapture scope;
        Future<void>? joined;
        host = AdeleHostRequestMultiplexer(
          send: (message) {
            sent.add(message);
            if (message['method'] == 'releaseCapture') {
              joined = scope.release();
              reply({'released': true});
            } else {
              reply(response());
            }
          },
        );
        client = AdeleCredentialClient(
          hostRequests: host,
          hostInfrastructureContext: 'captured-generation',
        );
        scope = await client.captureCurrentConfiguration();
        final releasing = scope.release();
        expect(identical(joined, releasing), isTrue);
        await releasing;
        expect(identical(scope.release(), releasing), isTrue);
        expect(sent, hasLength(2));
      },
    );

    test(
      'concurrent captures and reads retain independent scope and correlation',
      () async {
        final firstPending = client.captureCurrentConfiguration();
        final firstId = sent.last['requestId'];
        final secondPending = client.captureCurrentConfiguration();
        final secondId = sent.last['requestId'];
        reply(
          response(
            capture: nextHandle,
            records: [_record(id: 'personal')],
          ),
          requestId: secondId,
        );
        reply(response(records: [_record()]), requestId: firstId);
        final first = await firstPending;
        final second = await secondPending;
        expect(first.records.single['id'], 'work');
        expect(second.records.single['id'], 'personal');

        final firstRead = readCaptured(first);
        final firstReadId = sent.last['requestId'];
        expect((sent.last['payload'] as Map)['capture'], handle);
        final secondRead = readCaptured(second);
        final secondReadId = sent.last['requestId'];
        expect((sent.last['payload'] as Map)['capture'], nextHandle);
        final anotherSecondRead = readCaptured(second);
        final anotherSecondReadId = sent.last['requestId'];
        final startupRead = read();
        final startupReadId = sent.last['requestId'];
        expect(sent.last['method'], 'readCredential');
        expect((sent.last['payload'] as Map).containsKey('capture'), isFalse);
        final firstCheck = expectLater(
          firstRead,
          throwsA(_failure(AdeleCredentialFailureKind.staleConfiguration)),
        );
        final releasing = first.release();
        reply({'released': true});
        await releasing;
        reply({'secret': 'second-b'}, requestId: anotherSecondReadId);
        reply({'secret': 'startup'}, requestId: startupReadId);
        reply({'secret': 'must-not-publish'}, requestId: firstReadId);
        reply({'secret': 'second-a'}, requestId: secondReadId);
        expect(await secondRead, 'second-a');
        expect(await anotherSecondRead, 'second-b');
        expect(await startupRead, 'startup');
        await firstCheck;
        expect(
          sent.map((message) => message['requestId']).toSet(),
          hasLength(sent.length),
        );
      },
    );
  });
}

Map<String, Object?> _record({
  String id = 'work',
  Object? values = const <String, Object>{},
}) => {
  'collection': 'providers',
  'type': 'dev.adele.fixture.provider',
  'id': id,
  'values': values,
};

Matcher _failure(AdeleCredentialFailureKind kind) =>
    isA<AdeleCredentialFailure>()
        .having((failure) => failure.kind, 'kind', kind)
        .having(
          (failure) => failure.toString(),
          'bounded diagnostic',
          'Credential access failed (${kind.name}).',
        );
