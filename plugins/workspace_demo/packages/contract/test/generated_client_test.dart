import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:test/test.dart';
import 'package:workspace_demo_contract/workspace_demo_contract.dart';

void main() {
  test(
    'generated client sends stable method and reconstructs values',
    () async {
      final _Channel channel = _Channel(<String, Object?>{
        'directory': <String, Object?>{
          'uri': 'file:///demo/',
          'mediaType': null,
        },
        'entries': <Object?>[
          <String, Object?>{
            'resource': <String, Object?>{
              'uri': 'file:///demo/readme.txt',
              'mediaType': 'text/plain',
            },
            'name': 'readme.txt',
            'kind': 'file',
          },
        ],
      });

      final DirectoryListing result = await WorkspaceDemoServiceClient(
        channel,
      ).listDirectory(ResourceRef(uri: Uri.parse('file:///demo/')));

      expect(channel.method, 'workspaceDemo.listDirectory');
      expect(channel.payload?['directory'], isA<Map<Object?, Object?>>());
      expect(result.entries.single.name, 'readme.txt');
      expect(result.entries.single.kind, DirectoryEntryKind.file);
      expect(
        () => result.entries.add(result.entries.single),
        throwsUnsupportedError,
      );
    },
  );

  test('generated client translates structured remote failures', () async {
    final _FailingChannel channel = _FailingChannel();

    await expectLater(
      WorkspaceDemoServiceClient(
        channel,
      ).readTextFile(ResourceRef(uri: Uri.parse('file:///missing'))),
      throwsA(
        isA<WorkspaceDemoFailure>()
            .having(
              (WorkspaceDemoFailure value) => value.code,
              'code',
              'missing',
            )
            .having(
              (WorkspaceDemoFailure value) => value.details['path'],
              'path',
              '/missing',
            ),
      ),
    );
  });

  for (final String? declaredFailureType in <String?>[
    null,
    'another.failure',
  ]) {
    test('preserves remote failure with type $declaredFailureType', () async {
      final _RemoteFailure failure = _RemoteFailure(
        declaredFailureType: declaredFailureType,
        code: 'transport',
        message: 'Not declared by the service.',
      );
      await expectLater(
        WorkspaceDemoServiceClient(
          _ErrorChannel(failure),
        ).readTextFile(ResourceRef(uri: Uri.parse('file:///missing'))),
        throwsA(same(failure)),
      );
    });
  }

  test('preserves lifecycle and transport exceptions', () async {
    final StateError failure = StateError('connection closed');
    await expectLater(
      WorkspaceDemoServiceClient(
        _ErrorChannel(failure),
      ).readTextFile(ResourceRef(uri: Uri.parse('file:///missing'))),
      throwsA(same(failure)),
    );
  });

  test('generated client rejects malformed responses', () async {
    await expectLater(
      WorkspaceDemoServiceClient(
        _Channel(<String, Object?>{'entries': 'bad'}),
      ).listDirectory(ResourceRef(uri: Uri.parse('file:///demo/'))),
      throwsA(isA<AdeleProtocolException>()),
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

final class _FailingChannel implements AdeleRequestChannel {
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      Future<Object?>.error(
        const _RemoteFailure(
          declaredFailureType: 'workspaceDemo.failure',
          code: 'missing',
          message: 'Missing.',
          details: <String, Object?>{'path': '/missing'},
        ),
      );
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
    this.details = const {},
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
