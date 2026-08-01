import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:test/test.dart';
import 'package:workspace_demo_contract/workspace_demo_contract.dart';

void main() {
  test('dispatcher returns listDirectory success', () async {
    final response = await _dispatch(
      _request(workspaceDemoServiceListDirectoryId, {
        'directory': _resource('file:///demo'),
      }),
    );
    expect(response['ok'], isTrue);
    expect(
      ((response['payload'] as Map)['entries'] as List).single,
      containsPair('kind', 'file'),
    );
  });

  test('dispatcher returns readTextFile success', () async {
    final response = await _dispatch(
      _request(workspaceDemoServiceReadTextFileId, {
        'file': _resource('file:///demo/readme.txt'),
      }),
    );
    expect(response['ok'], isTrue);
    expect((response['payload'] as Map)['text'], 'text');
  });

  test('dispatcher rejects a missing envelope field', () async {
    final request = _validRequest()..remove('kind');
    await _expectInvalid(request);
  });

  test('dispatcher rejects an extra envelope field', () async {
    await _expectInvalid({..._validRequest(), 'extra': true});
  });

  test('dispatcher rejects a wrong envelope kind', () async {
    await _expectInvalid({..._validRequest(), 'kind': 'response'});
  });

  test('dispatcher rejects a wrong request ID type', () async {
    await _expectInvalid({..._validRequest(), 'requestId': '7'});
  });

  test('dispatcher rejects a wrong method type', () async {
    await _expectInvalid({..._validRequest(), 'method': 1});
  });

  test('dispatcher rejects a wrong payload type', () async {
    await _expectInvalid({..._validRequest(), 'payload': 'bad'});
  });

  test('dispatcher rejects a missing argument', () async {
    await _expectInvalid({..._validRequest(), 'payload': <String, Object?>{}});
  });

  test('dispatcher rejects an unexpected argument', () async {
    await _expectInvalid({
      ..._validRequest(),
      'payload': {'directory': _resource('file:///demo'), 'extra': true},
    });
  });

  test('dispatcher rejects an invalid nested ResourceRef uri', () async {
    await _expectInvalid({
      ..._validRequest(),
      'payload': {
        'directory': {'uri': 1, 'mediaType': null},
      },
    });
  });

  test('dispatcher rejects an invalid nested ResourceRef mediaType', () async {
    await _expectInvalid({
      ..._validRequest(),
      'payload': {
        'directory': {'uri': 'file:///demo', 'mediaType': 1},
      },
    });
  });

  test('dispatcher returns a declared service failure', () async {
    final response = await WorkspaceDemoServiceDispatcher(
      const _ThrowingService(true),
    ).dispatch(_validRequest());
    expect(response['ok'], isFalse);
    expect(response['requestId'], 10);
    expect(
      response['error'],
      containsPair('declaredFailureType', 'workspaceDemo.failure'),
    );
    expect(response['error'], containsPair('code', 'denied'));
  });

  test('dispatcher contains an unexpected service failure', () async {
    final response = await WorkspaceDemoServiceDispatcher(
      const _ThrowingService(false),
    ).dispatch(_validRequest());
    expect(response['error'], containsPair('code', 'internal_error'));
    expect((response['error'] as Map)['message'], isNot(contains('secret')));
  });

  test('dispatcher returns unknown method failure', () async {
    final response = await _dispatch(_request('unknown', const {}));
    expect(response['error'], containsPair('code', 'unknown_method'));
  });

  test('dispatcher classifies unknown method before payload decoding', () async {
    final response = await _dispatch({
      ..._request('unknown', const {}),
      'payload': DateTime(2020),
    });
    expect(response['error'], containsPair('code', 'unknown_method'));
  });

  test('dispatcher omits malformed request ID from failure', () async {
    final response = await _dispatch({..._validRequest(), 'requestId': 'bad'});
    expect(response['error'], containsPair('code', 'invalid_request'));
    expect(response.containsKey('requestId'), isFalse);
  });

  test('dispatcher preserves request ID on success', () async {
    final response = await _dispatch({..._validRequest(), 'requestId': 2468});
    expect(response['requestId'], 2468);
  });

  test('dispatcher preserves request ID on protocol failure', () async {
    final response = await _dispatch({
      ..._validRequest(),
      'requestId': 1357,
      'payload': <String, Object?>{},
    });
    expect(response['requestId'], 1357);
  });
}

Map<String, Object?> _resource(String uri) => {'uri': uri, 'mediaType': null};
Map<String, Object?> _request(String method, Map<String, Object?> payload) => {
  'kind': 'request',
  'requestId': 10,
  'method': method,
  'payload': payload,
};
Map<String, Object?> _validRequest() => _request(
  workspaceDemoServiceListDirectoryId,
  {'directory': _resource('file:///demo')},
);
Future<Map<String, Object?>> _dispatch(Map<Object?, Object?> request) =>
    WorkspaceDemoServiceDispatcher(_FakeService()).dispatch(request);
Future<void> _expectInvalid(Map<Object?, Object?> request) async {
  final response = await _dispatch(request);
  expect(response['ok'], isFalse);
  expect(response['error'], containsPair('code', 'invalid_request'));
}

final class _ThrowingService implements WorkspaceDemoService {
  const _ThrowingService(this.declared);
  final bool declared;
  @override
  Future<DirectoryListing> listDirectory(ResourceRef directory) {
    if (declared) {
      throw const WorkspaceDemoFailure(code: 'denied', message: 'Denied.');
    }
    throw StateError('secret implementation detail');
  }

  @override
  Future<TextFileContents> readTextFile(ResourceRef file) =>
      throw UnimplementedError();
}

final class _FakeService implements WorkspaceDemoService {
  @override
  Future<DirectoryListing> listDirectory(ResourceRef directory) async =>
      DirectoryListing(
        directory: directory,
        entries: [
          DirectoryEntry(
            resource: ResourceRef(uri: Uri.parse('file:///demo/readme.txt')),
            name: 'readme.txt',
            kind: DirectoryEntryKind.file,
          ),
        ],
      );
  @override
  Future<TextFileContents> readTextFile(ResourceRef file) async =>
      TextFileContents(resource: file, text: 'text');
}
