import 'support/contract_generator_support.dart';

void main() {
  for (final (bool, bool) streams in <(bool, bool)>[
    (false, false),
    (false, true),
    (true, false),
    (true, true),
  ]) {
    test(
      'local services share codecs and failures with streams $streams',
      () async {
        final String source = _contract(streams);
        final String generated = await generateContract(source);
        expect(
          await generateContract(_contract(streams, reverse: true)),
          generated,
        );
        for (final String declaration in <String>[
          'String _decodeContractEnvelope(',
          'final class _ContractUnknownMethod ',
          'Map<String, Object?> _contractFailure(',
          'Map<String, Object?> _encodeSharedValue(',
          'SharedValue _decodeSharedValue(',
          'const String sharedFailureTypeId ',
        ]) {
          expect(declaration.allMatches(generated), hasLength(1));
        }
        for (final String declaration in <String>[
          'final class _ContractStreamState ',
          'Map<String, Object?> _contractStreamFailure(',
        ]) {
          expect(
            declaration.allMatches(generated),
            hasLength(streams.$1 || streams.$2 ? 1 : 0),
          );
        }
        await runGeneratedFixture(source, _runtimeTests(streams));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test('rejects generated symbol collisions between local services', () async {
    await expectDiagnostic(
      _contract((false, false)).replaceAll('BetaService', 'alphaService'),
      'Generated symbol collision for alphaServiceId',
    );
  });

  test(
    'services without declared failures compile and propagate remote failures',
    () async {
      await runGeneratedFixture(
        _contract((true, false), failures: false),
        _runtimeTests((true, false), failures: false),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

String _contract(
  (bool, bool) streams, {
  bool reverse = false,
  bool failures = true,
}) {
  final List<String> services = <String>[
    for (final (String, bool) service in <(String, bool)>[
      ('Alpha', streams.$1),
      ('Beta', streams.$2),
    ])
      '''
@AdeleService('fixture.${service.$1.toLowerCase()}')
abstract interface class ${service.$1}Service {
  @AdeleMethod('read') Future<SharedValue> read(SharedValue value);
  ${service.$2 ? "@AdeleMethod('watch') Stream<SharedValue> watch(SharedValue value);" : ''}
}
''',
  ];
  return '''
import 'package:adele_contract/adele_contract.dart';
part 'fixture.g.dart';
@AdeleValue('fixture.shared')
final class SharedValue {
  const SharedValue({required this.text, required this.revision});
  final String text;
  final String? revision;
}
${(reverse ? services.reversed : services).join()}
${failures ? '''
@AdeleFailure('fixture.failure')
final class SharedFailure implements Exception {
  const SharedFailure({required this.code, required this.message, required this.details});
  final String code;
  final String message;
  final Map<String, Object?> details;
}
''' : ''}
''';
}

String _runtimeTests((bool, bool) streams, {bool failures = true}) =>
    '''
import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:generated_contract_fixture/fixture.dart';
import 'package:test/test.dart';

void main() {
  test('both generated services execute with shared value and failure types', () async {
    final backend = _Service();
    final alpha = AlphaServiceDispatcher(backend);
    final beta = BetaServiceDispatcher(backend);
    addTearDown(alpha.close);
    addTearDown(beta.close);
    final alphaClient = AlphaServiceClient(_Channel(alpha));
    final betaClient = BetaServiceClient(_Channel(beta));
    const value = SharedValue(text: 'exact text', revision: null);
    for (final read in [alphaClient.read, betaClient.read]) {
      final result = await read(value);
      expect(result, isNot(same(value)));
      expect(result.text, value.text);
      expect(result.revision, isNull);
      await expectLater(
        read(const SharedValue(text: 'fail', revision: 'opaque')),
        throwsA(${failures ? "isA<SharedFailure>().having((error) => error.code, 'code', 'rejected').having((error) => error.details['revision'], 'revision', 'opaque')" : "isA<AdeleRemoteFailure>().having((error) => error.code, 'code', 'internal_error')"}),
      );
    }
    for (final dispatcher in <AdeleBackendDispatcher>[alpha, beta]) {
      final response = await dispatcher.dispatch({
        'kind': 'request', 'requestId': 1,
        'method': identical(dispatcher, alpha) ? betaServiceReadId : alphaServiceReadId,
        'payload': {'value': {'text': 'wrong service', 'revision': null}},
      });
      expect((response['error'] as Map)['code'], 'unknown_method');
    }
    ${streams.$1 || streams.$2 ? '''
    for (final watch in [${[if (streams.$1) 'alphaClient.watch', if (streams.$2) 'betaClient.watch'].join(',')}]) {
      final result = await watch(value).toList();
      expect(result.single.text, value.text);
      expect(result.single.revision, isNull);
      expect(result.single, isNot(same(value)));
      await expectLater(
        watch(const SharedValue(text: 'fail', revision: 'opaque')),
        emitsError(${failures ? "isA<SharedFailure>().having((error) => error.code, 'code', 'rejected').having((error) => error.details['revision'], 'revision', 'opaque')" : "isA<AdeleRemoteFailure>().having((error) => error.code, 'code', 'internal_error')"}),
      );
      expect((await watch(value).toList()).single.text, value.text);
    }
    ''' : ''}
  });
}

final class _Service implements AlphaService, BetaService {
  @override
  Future<SharedValue> read(SharedValue value) async {
    if (value.text == 'fail') {
      throw ${failures ? "SharedFailure(code: 'rejected', message: 'Shared failure.', details: {'revision': value.revision})" : "StateError('private failure detail')"};
    }
    return value;
  }
  ${streams.$1 || streams.$2 ? '''
  @override
  Stream<SharedValue> watch(SharedValue value) async* {
    yield await read(value);
  }
  ''' : ''}
}

final class _Channel implements AdeleStreamChannel {
  _Channel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
  int nextId = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    final response = await dispatcher.dispatch({
      'kind': 'request', 'requestId': ++nextId, 'method': method, 'payload': payload,
    });
    if (response['ok'] != true) throw _RemoteFailure(response['error'] as Map);
    return response['payload'];
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) async* {
    final id = ++nextId;
    final events = StreamController<Object?>();
    void send(Map<String, Object?> event) {
      switch (event['kind']) {
        case 'streamItem':
          events.add(event['payload']);
        case 'streamFailure':
          events.addError(_RemoteFailure(event['error'] as Map));
          unawaited(events.close());
        case 'streamDone':
          unawaited(events.close());
      }
    }
    try {
      await dispatcher.handle({'kind': 'streamOpen', 'requestId': id, 'method': method, 'payload': payload}, send);
      await dispatcher.handle({'kind': 'streamCredit', 'requestId': id, 'credit': 4}, send);
      yield* events.stream;
    } finally {
      await dispatcher.handle({'kind': 'streamCancel', 'requestId': id}, send);
    }
  }
}

final class _RemoteFailure implements AdeleRemoteFailure {
  const _RemoteFailure(this.error);
  final Map<dynamic, dynamic> error;
  @override String? get declaredFailureType => error['declaredFailureType'] as String?;
  @override String get code => error['code'] as String;
  @override String get message => error['message'] as String;
  @override Map<String, Object?> get details => Map<String, Object?>.from(error['details'] as Map);
}
''';
