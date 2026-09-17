import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:test/test.dart';

void main() {
  late _ReadService service;
  late AuthorizedEnvironmentReadServiceDispatcher dispatcher;
  late _Channel channel;
  late AuthorizedEnvironmentReadServiceClient client;

  setUp(() {
    service = _ReadService();
    dispatcher = AuthorizedEnvironmentReadServiceDispatcher(service);
    channel = _Channel(dispatcher);
    client = AuthorizedEnvironmentReadServiceClient(channel);
  });
  tearDown(() => dispatcher.close());

  test(
    'authorized read roundtrips the existing text-file DTO with only a path',
    () async {
      final EnvironmentTextFile file = await client.readFile('AGENTS.md');

      expect(authorizedEnvironmentReadServiceId, 'authorizedEnvironmentRead');
      expect(channel.method, 'authorizedEnvironmentRead.readFile');
      expect(channel.payload, <String, Object?>{'relativePath': 'AGENTS.md'});
      expect(service.path, 'AGENTS.md');
      expect(file.relativePath, 'AGENTS.md');
      expect(file.text, '  instruction\n');
      expect(file.sizeBytes, 14);
      expect(file.revision, 'opaque-revision');
      expect(file, isNot(same(service.file)));
    },
  );

  test(
    'authorized read reconstructs the existing declared EnvironmentFailure',
    () async {
      for (final String code in <String>['not_found', 'permission_denied']) {
        service.failure = EnvironmentFailure(
          code: code,
          message: 'Read rejected.',
          details: const <String, Object?>{'relativePath': 'AGENTS.md'},
        );
        await expectLater(
          client.readFile('AGENTS.md'),
          throwsA(
            isA<EnvironmentFailure>()
                .having((EnvironmentFailure error) => error.code, 'code', code)
                .having(
                  (EnvironmentFailure error) => error.message,
                  'message',
                  'Read rejected.',
                )
                .having(
                  (EnvironmentFailure error) => error.details,
                  'details',
                  <String, Object?>{'relativePath': 'AGENTS.md'},
                ),
          ),
        );
        expect(
          (channel.response!['error']!
              as Map<Object?, Object?>)['declaredFailureType'],
          environmentFailureTypeId,
        );
      }
      service.failure = null;
      expect((await client.readFile('AGENTS.md')).revision, 'opaque-revision');
    },
  );

  test(
    'authorized read contains unexpected failures without exposing details',
    () async {
      service.failure = StateError('private authority detail');
      await expectLater(
        client.readFile('AGENTS.md'),
        throwsA(
          isA<AdeleRemoteFailure>()
              .having(
                (AdeleRemoteFailure error) => error.code,
                'code',
                'internal_error',
              )
              .having(
                (AdeleRemoteFailure error) => error.declaredFailureType,
                'type',
                isNull,
              )
              .having(
                (AdeleRemoteFailure error) => error.message,
                'message',
                isNot(contains('private')),
              ),
        ),
      );
    },
  );

  test(
    'authorized read rejects authority IDs and provider operations',
    () async {
      for (final Map<String, Object?> payload in <Map<String, Object?>>[
        <String, Object?>{},
        <String, Object?>{'relativePath': 1},
        for (final String field in <String>[
          'sessionId',
          'environmentId',
          'hostInvocationContext',
        ])
          <String, Object?>{
            'relativePath': 'AGENTS.md',
            field: 'not-transported',
          },
      ]) {
        final Map<String, Object?> response = await dispatcher.dispatch(
          _request(authorizedEnvironmentReadServiceReadFileId, payload),
        );
        expect(
          (response['error']! as Map<Object?, Object?>)['code'],
          'invalid_request',
        );
      }
      for (final String method in <String>[
        environmentProviderServiceReadFileId,
        'authorizedEnvironmentRead.readDirectory',
        'authorizedEnvironmentRead.replaceExistingTextFile',
        'authorizedEnvironmentRead.runForegroundProcess',
      ]) {
        final Map<String, Object?> response = await dispatcher.dispatch(
          _request(method, <String, Object?>{'relativePath': 'AGENTS.md'}),
        );
        expect(
          (response['error']! as Map<Object?, Object?>)['code'],
          'unknown_method',
        );
      }
      expect(service.path, isNull);
    },
  );
}

Map<Object?, Object?> _request(String method, Map<String, Object?> payload) =>
    <Object?, Object?>{
      'kind': 'request',
      'requestId': 1,
      'method': method,
      'payload': payload,
    };

final class _ReadService implements AuthorizedEnvironmentReadService {
  final EnvironmentTextFile file = const EnvironmentTextFile(
    relativePath: 'AGENTS.md',
    text: '  instruction\n',
    sizeBytes: 14,
    revision: 'opaque-revision',
  );
  String? path;
  Object? failure;

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    path = relativePath;
    if (failure case final Object error) throw error;
    return file;
  }
}

final class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
  String? method;
  Map<String, Object?>? payload;
  Map<String, Object?>? response;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    this.payload = payload;
    final Map<String, Object?> response = await dispatcher.dispatch(
      _request(method, payload),
    );
    this.response = response;
    if (response['ok'] != true) {
      throw _RemoteFailure(response['error']! as Map<Object?, Object?>);
    }
    return response['payload'];
  }
}

final class _RemoteFailure implements AdeleRemoteFailure {
  const _RemoteFailure(this.error);
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
