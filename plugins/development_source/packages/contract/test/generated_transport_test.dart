import 'package:adele_contract/adele_contract.dart';
import 'package:development_source_contract/development_source_contract.dart';
import 'package:test/test.dart';

void main() {
  test('generated client encodes read and decodes file identity', () async {
    final _Channel channel = _Channel(<String, Object?>{
      'relativePath': 'lib/main.dart',
      'text': 'void main() {}',
      'sizeBytes': 14,
    });

    final DevelopmentSourceTextFile result =
        await DevelopmentSourceServiceClient(
          channel,
        ).readTextFile('lib/main.dart');

    expect(channel.method, developmentSourceServiceReadTextFileId);
    expect(channel.payload, <String, Object?>{'relativePath': 'lib/main.dart'});
    expect(result.relativePath, 'lib/main.dart');
    expect(result.text, 'void main() {}');
  });

  test('generated client decodes bounded search results', () async {
    final _Channel channel = _Channel(<String, Object?>{
      'matches': <Object?>[
        <String, Object?>{
          'relativePath': 'lib/a.dart',
          'lineNumber': 3,
          'snippet': 'final answer = 42;',
        },
      ],
      'truncated': true,
    });

    final DevelopmentSourceSearchResult result =
        await DevelopmentSourceServiceClient(channel).searchText('answer');

    expect(channel.method, developmentSourceServiceSearchTextId);
    expect(channel.payload, <String, Object?>{'literalText': 'answer'});
    expect(result.matches.single.relativePath, 'lib/a.dart');
    expect(result.matches.single.lineNumber, 3);
    expect(result.truncated, isTrue);
    expect(() => result.matches.clear(), throwsUnsupportedError);
  });

  test('generated client reconstructs declared domain failure', () async {
    await expectLater(
      DevelopmentSourceServiceClient(
        const _ErrorChannel(
          _RemoteFailure(
            declaredFailureType: 'developmentSource.failure',
            code: 'invalid_path',
            message: 'Invalid path.',
            details: <String, Object?>{'relativePath': '../secret'},
          ),
        ),
      ).readTextFile('../secret'),
      throwsA(
        isA<DevelopmentSourceFailure>()
            .having(
              (DevelopmentSourceFailure failure) => failure.code,
              'code',
              'invalid_path',
            )
            .having(
              (DevelopmentSourceFailure failure) => failure.details,
              'details',
              <String, Object?>{'relativePath': '../secret'},
            ),
      ),
    );
  });
}

final class _Channel implements AdeleRequestChannel {
  _Channel(this.response);

  final Object? response;
  String? method;
  Map<String, Object?>? payload;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    this.payload = payload;
    return response;
  }
}

final class _ErrorChannel implements AdeleRequestChannel {
  const _ErrorChannel(this.error);

  final Object error;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      Future<Object?>.error(error);
}

final class _RemoteFailure implements AdeleRemoteFailure {
  const _RemoteFailure({
    required this.declaredFailureType,
    required this.code,
    required this.message,
    required this.details,
  });

  @override
  final String? declaredFailureType;
  @override
  final String code;
  @override
  final String message;
  @override
  final Map<String, Object?> details;
}
