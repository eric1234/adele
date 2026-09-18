import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:test/test.dart';

void main() {
  late _MutationService service;
  late AuthorizedEnvironmentMutationServiceDispatcher dispatcher;
  late _Channel channel;
  late AuthorizedEnvironmentMutationServiceClient client;

  setUp(() {
    service = _MutationService();
    dispatcher = AuthorizedEnvironmentMutationServiceDispatcher(service);
    channel = _Channel(dispatcher);
    client = AuthorizedEnvironmentMutationServiceClient(channel);
  });
  tearDown(() => dispatcher.close());

  test(
    'mutations roundtrip existing outputs without authority selectors',
    () async {
      expect(
        authorizedEnvironmentMutationServiceId,
        'authorizedEnvironmentMutation',
      );
      final creation = await client.createTextFile('lib/new.dart', ' exact\n');
      expect(channel.method, 'authorizedEnvironmentMutation.createTextFile');
      expect(channel.payload, {
        'relativePath': 'lib/new.dart',
        'text': ' exact\n',
      });
      expect(service.calls.last, ['create', 'lib/new.dart', ' exact\n']);
      expect(creation.revision, service.creation.revision);
      expect(creation, isNot(same(service.creation)));

      final replacement = await client.replaceExistingTextFile(
        'lib/new.dart',
        'replacement\n',
        creation.revision,
      );
      expect(
        channel.method,
        'authorizedEnvironmentMutation.replaceExistingTextFile',
      );
      expect(channel.payload, {
        'relativePath': 'lib/new.dart',
        'replacementText': 'replacement\n',
        'expectedRevision': creation.revision,
      });
      expect(service.calls.last, [
        'replace',
        'lib/new.dart',
        'replacement\n',
        creation.revision,
      ]);
      expect(replacement.revision, service.replacement.revision);
      expect(replacement, isNot(same(service.replacement)));

      await client.deleteExistingTextFile('lib/new.dart', replacement.revision);
      expect(
        channel.method,
        'authorizedEnvironmentMutation.deleteExistingTextFile',
      );
      expect(channel.payload, {
        'relativePath': 'lib/new.dart',
        'expectedRevision': replacement.revision,
      });
      expect(service.calls.last, [
        'delete',
        'lib/new.dart',
        replacement.revision,
      ]);
      expect(channel.response!['payload'], isNull);
    },
  );

  test(
    'every mutation reconstructs the shared declared failures exactly',
    () async {
      for (final invoke in _operations(client)) {
        for (final code in [
          environmentFileAlreadyExistsCode,
          environmentRevisionConflictCode,
          'not_found',
          'permission_denied',
        ]) {
          final failure = EnvironmentFailure(
            code: code,
            message: 'Mutation rejected.',
            details: {
              'relativePath': 'lib/file.dart',
              'expectedRevision': 'opaque-observed',
            },
          );
          service.failure = failure;
          await expectLater(
            invoke(),
            throwsA(
              isA<EnvironmentFailure>()
                  .having((error) => error.code, 'code', code)
                  .having((error) => error.message, 'message', failure.message)
                  .having((error) => error.details, 'details', failure.details)
                  .having(
                    (error) => identical(error, failure),
                    'reconstructed',
                    isFalse,
                  ),
            ),
          );
          expect(
            (channel.response!['error']! as Map)['declaredFailureType'],
            environmentFailureTypeId,
          );
        }
      }
    },
  );

  test(
    'undeclared failures stay opaque and unknown remote failures pass through',
    () async {
      service.failure = StateError('private mutation authority');
      for (final invoke in _operations(client)) {
        await expectLater(
          invoke(),
          throwsA(
            isA<AdeleRemoteFailure>()
                .having((error) => error.code, 'code', 'internal_error')
                .having((error) => error.declaredFailureType, 'type', isNull)
                .having(
                  (error) => error.message,
                  'message',
                  isNot(contains('private')),
                ),
          ),
        );
      }
      final unknown = _RemoteFailure({
        'declaredFailureType': 'other.failure',
        'code': 'unavailable',
        'message': 'Not an Environment failure.',
        'details': <String, Object?>{},
      });
      for (final invoke in _operations(
        AuthorizedEnvironmentMutationServiceClient(
          _ResponseChannel(failure: unknown),
        ),
      )) {
        await expectLater(invoke(), throwsA(same(unknown)));
      }
    },
  );

  test(
    'mutation dispatch rejects malformed arguments and authority selectors',
    () async {
      final payloads = {
        authorizedEnvironmentMutationServiceCreateTextFileId: <String, Object?>{
          'relativePath': 'file',
          'text': '',
        },
        authorizedEnvironmentMutationServiceReplaceExistingTextFileId:
            <String, Object?>{
              'relativePath': 'file',
              'replacementText': '',
              'expectedRevision': 'observed',
            },
        authorizedEnvironmentMutationServiceDeleteExistingTextFileId:
            <String, Object?>{
              'relativePath': 'file',
              'expectedRevision': 'observed',
            },
      };
      for (final entry in payloads.entries) {
        for (final payload in <Map<String, Object?>>[
          for (final field in entry.value.keys) {...entry.value}..remove(field),
          for (final field in entry.value.keys) {...entry.value, field: 1},
          for (final selector in [
            'sessionId',
            'taskId',
            'runId',
            'environmentId',
            'providerId',
            'hostInvocationContext',
          ])
            {...entry.value, selector: 'forged'},
        ]) {
          final response = await dispatcher.dispatch(
            _request(entry.key, payload),
          );
          expect((response['error']! as Map)['code'], 'invalid_request');
        }
      }
      expect(service.calls, isEmpty);
    },
  );

  test(
    'mutation service exposes no identity, read, provider or process methods',
    () async {
      for (final method in [
        'authorizedEnvironmentMutation.authority',
        'authorizedEnvironmentMutation.readFile',
        'authorizedEnvironmentMutation.readDirectory',
        'authorizedEnvironmentMutation.runForegroundProcess',
        authorizedEnvironmentReadServiceReadFileId,
        environmentProviderServiceCreateTextFileId,
      ]) {
        final response = await dispatcher.dispatch(_request(method, {}));
        expect((response['error']! as Map)['code'], 'unknown_method');
      }
      expect(service.calls, isEmpty);
    },
  );

  test(
    'mutation clients reject malformed output and preserve creation invariant',
    () async {
      for (final response in <Object?>[
        null,
        {},
        {'revision': 1},
        {'revision': 'revision', 'extra': true},
      ]) {
        final malformed = AuthorizedEnvironmentMutationServiceClient(
          _ResponseChannel(response: response),
        );
        await expectLater(
          malformed.createTextFile('file', ''),
          throwsA(isA<AdeleProtocolException>()),
        );
        await expectLater(
          malformed.replaceExistingTextFile('file', '', 'observed'),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
      await expectLater(
        AuthorizedEnvironmentMutationServiceClient(
          _ResponseChannel(response: {'revision': ''}),
        ).createTextFile('file', ''),
        throwsA(isA<AdeleProtocolException>()),
      );
      await expectLater(
        AuthorizedEnvironmentMutationServiceClient(
          _ResponseChannel(response: {}),
        ).deleteExistingTextFile('file', 'observed'),
        throwsA(isA<AdeleProtocolException>()),
      );
    },
  );
}

List<Future<void> Function()> _operations(
  AuthorizedEnvironmentMutationServiceClient client,
) => [
  () async {
    await client.createTextFile('lib/file.dart', 'text');
  },
  () async {
    await client.replaceExistingTextFile(
      'lib/file.dart',
      'replacement',
      'opaque-observed',
    );
  },
  () => client.deleteExistingTextFile('lib/file.dart', 'opaque-observed'),
];

final class _MutationService implements AuthorizedEnvironmentMutationService {
  final creation = EnvironmentTextFileCreation(revision: 'opaque-created');
  final replacement = const EnvironmentTextFileReplacement(
    revision: 'opaque-replaced',
  );
  final calls = <List<String>>[];
  Object? failure;

  @override
  Future<EnvironmentTextFileCreation> createTextFile(
    String relativePath,
    String text,
  ) async {
    calls.add(['create', relativePath, text]);
    if (failure case final error?) throw error;
    return creation;
  }

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) async {
    calls.add(['replace', relativePath, replacementText, expectedRevision]);
    if (failure case final error?) throw error;
    return replacement;
  }

  @override
  Future<void> deleteExistingTextFile(
    String relativePath,
    String expectedRevision,
  ) async {
    calls.add(['delete', relativePath, expectedRevision]);
    if (failure case final error?) throw error;
  }
}

Map<String, Object?> _request(String method, Map<String, Object?> payload) => {
  'kind': 'request',
  'requestId': 1,
  'method': method,
  'payload': payload,
};

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
    final response = await dispatcher.dispatch(_request(method, payload));
    this.response = response;
    if (response['ok'] != true) throw _RemoteFailure(response['error']! as Map);
    return response['payload'];
  }
}

final class _ResponseChannel implements AdeleRequestChannel {
  const _ResponseChannel({this.response, this.failure});
  final Object? response;
  final Object? failure;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    if (failure case final error?) throw error;
    return response;
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
