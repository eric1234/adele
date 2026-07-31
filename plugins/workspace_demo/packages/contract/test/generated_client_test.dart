import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:test/test.dart';
import 'package:workspace_demo_contract/workspace_demo_contract.dart';

void main() {
  test(
    'ResourceRef codec round-trips through client payload and response',
    () async {
      final channel = _Channel(_listingResponse());
      final input = ResourceRef(
        uri: Uri.parse('file:///demo/'),
        mediaType: 'inode/directory',
      );
      final result = await WorkspaceDemoServiceClient(
        channel,
      ).listDirectory(input);
      expect(channel.payload?['directory'], {
        'uri': 'file:///demo/',
        'mediaType': 'inode/directory',
      });
      expect(result.directory.uri, input.uri);
      expect(result.directory.mediaType, input.mediaType);
    },
  );

  test('client decodes enum value list and text fields', () async {
    final result = await WorkspaceDemoServiceClient(
      _Channel(_listingResponse()),
    ).listDirectory(ResourceRef(uri: Uri.parse('file:///demo/')));
    expect(result.entries.single.kind, DirectoryEntryKind.file);
    expect(result.entries.single.name, 'readme.txt');
    expect(result.entries, hasLength(1));
  });

  test('client preserves structured failure details recursively', () async {
    final details = <String, Object?>{
      'path': '/missing',
      'nested': <String, Object?>{
        'attempts': <Object?>[1, true, null],
      },
    };
    await expectLater(
      WorkspaceDemoServiceClient(
        _ErrorChannel(
          _RemoteFailure(
            declaredFailureType: 'workspaceDemo.failure',
            code: 'missing',
            message: 'Missing.',
            details: details,
          ),
        ),
      ).readTextFile(ResourceRef(uri: Uri.parse('file:///missing'))),
      throwsA(
        isA<WorkspaceDemoFailure>()
            .having((e) => e.message, 'message', 'Missing.')
            .having((e) => e.details, 'details', details),
      ),
    );
  });

  test('client decodes nullable ResourceRef mediaType', () async {
    final result = await WorkspaceDemoServiceClient(
      _Channel(_listingResponse(mediaType: null)),
    ).listDirectory(ResourceRef(uri: Uri.parse('file:///demo/')));
    expect(result.directory.mediaType, isNull);
  });

  test('client returns immutable decoded lists', () async {
    final result = await WorkspaceDemoServiceClient(
      _Channel(_listingResponse()),
    ).listDirectory(ResourceRef(uri: Uri.parse('file:///demo/')));
    expect(() => result.entries.clear(), throwsUnsupportedError);
  });

  test('client rejects an invalid enum value', () async {
    final response = _listingResponse();
    ((response['entries'] as List).single as Map)['kind'] = 'link';
    await _expectProtocol(response);
  });

  test('client rejects a missing top-level response field', () async {
    final response = _listingResponse()..remove('directory');
    await _expectProtocol(response);
  });

  test('client rejects a wrong top-level response field type', () async {
    final response = _listingResponse()..['entries'] = 'bad';
    await _expectProtocol(response);
  });

  test('client rejects a missing nested value field', () async {
    final response = _listingResponse();
    ((response['entries'] as List).single as Map).remove('name');
    await _expectProtocol(response);
  });

  test('client rejects a wrong nested ResourceRef field type', () async {
    final response = _listingResponse();
    ((response['entries'] as List).single as Map)['resource'] =
        <String, Object?>{'uri': 1, 'mediaType': 'text/plain'};
    await _expectProtocol(response);
  });

  test('client calls listDirectory with its stable method ID', () async {
    final channel = _Channel(_listingResponse());
    await WorkspaceDemoServiceClient(
      channel,
    ).listDirectory(ResourceRef(uri: Uri.parse('file:///demo/')));
    expect(channel.method, workspaceDemoServiceListDirectoryId);
  });

  test('client calls readTextFile and decodes text contents', () async {
    final channel = _Channel(<String, Object?>{
      'resource': {'uri': 'file:///demo/readme.txt', 'mediaType': 'text/plain'},
      'text': 'hello',
    });
    final result = await WorkspaceDemoServiceClient(
      channel,
    ).readTextFile(ResourceRef(uri: Uri.parse('file:///demo/readme.txt')));
    expect(channel.method, workspaceDemoServiceReadTextFileId);
    expect(result.text, 'hello');
  });

  test('client rejects a malformed method response', () async {
    await _expectProtocol(<String, Object?>{'entries': 'bad'});
  });

  test('client preserves undeclared remote failures', () async {
    const failure = _RemoteFailure(
      declaredFailureType: 'other.failure',
      code: 'x',
      message: 'x',
    );
    await expectLater(
      WorkspaceDemoServiceClient(
        const _ErrorChannel(failure),
      ).readTextFile(ResourceRef(uri: Uri.parse('file:///missing'))),
      throwsA(same(failure)),
    );
  });
}

Map<String, Object?> _listingResponse({
  String? mediaType = 'inode/directory',
}) => {
  'directory': {'uri': 'file:///demo/', 'mediaType': mediaType},
  'entries': <Object?>[
    {
      'resource': {'uri': 'file:///demo/readme.txt', 'mediaType': 'text/plain'},
      'name': 'readme.txt',
      'kind': 'file',
    },
  ],
};

Future<void> _expectProtocol(Object? response) async {
  await expectLater(
    WorkspaceDemoServiceClient(
      _Channel(response),
    ).listDirectory(ResourceRef(uri: Uri.parse('file:///demo/'))),
    throwsA(isA<AdeleProtocolException>()),
  );
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
      Future.error(error);
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
