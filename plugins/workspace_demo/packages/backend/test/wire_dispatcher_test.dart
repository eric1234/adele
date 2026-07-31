import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:test/test.dart';
import 'package:workspace_demo_contract/workspace_demo_contract.dart';

void main() {
  test('encodes a nested typed directory listing', () async {
    final WorkspaceDemoServiceDispatcher dispatcher =
        WorkspaceDemoServiceDispatcher(_FakeService());
    final Map<String, Object?> response = await dispatcher.dispatch(
      <String, Object?>{
        'kind': 'request',
        'requestId': 7,
        'method': 'workspaceDemo.listDirectory',
        'payload': <String, Object?>{
          'directory': <String, Object?>{
            'uri': 'file:///demo',
            'mediaType': null,
          },
        },
      },
    );
    expect(response['requestId'], 7);
    expect(response['ok'], isTrue);
    final Map<Object?, Object?> payload = response['payload'] as Map;
    final List<Object?> entries = payload['entries'] as List<Object?>;
    expect((entries.single as Map)['kind'], 'file');
  });

  test(
    'returns structured errors for unknown and malformed requests',
    () async {
      final WorkspaceDemoServiceDispatcher dispatcher =
          WorkspaceDemoServiceDispatcher(_FakeService());
      final Map<String, Object?> unknown = await dispatcher
          .dispatch(<String, Object?>{
            'kind': 'request',
            'requestId': 8,
            'method': 'unknown',
            'payload': <String, Object?>{},
          });
      expect((unknown['error'] as Map)['code'], 'unknown_method');
      final Map<String, Object?> malformed = await dispatcher.dispatch(
        <String, Object?>{
          'kind': 'request',
          'requestId': 9,
          'method': 'workspaceDemo.listDirectory',
          'payload': <String, Object?>{'directory': 'bad'},
        },
      );
      expect((malformed['error'] as Map)['code'], 'invalid_request');
    },
  );

  final Map<String, Object?> valid = <String, Object?>{
    'kind': 'request',
    'requestId': 10,
    'method': 'workspaceDemo.listDirectory',
    'payload': <String, Object?>{
      'directory': <String, Object?>{'uri': 'file:///demo', 'mediaType': null},
    },
  };
  final Map<String, Map<Object?, Object?> Function()> malformed = {
    'missing envelope field': () =>
        Map<Object?, Object?>.of(valid)..remove('kind'),
    'extra envelope field': () => <Object?, Object?>{...valid, 'extra': true},
    'missing payload field': () => <Object?, Object?>{
      ...valid,
      'payload': <String, Object?>{},
    },
    'extra payload field': () => <Object?, Object?>{
      ...valid,
      'payload': <String, Object?>{
        ...(valid['payload']! as Map<String, Object?>),
        'extra': true,
      },
    },
    'non-string map key': () => <Object?, Object?>{
      ...valid,
      'payload': <Object?, Object?>{1: 'bad'},
    },
    'malformed nested map': () => <Object?, Object?>{
      ...valid,
      'payload': <String, Object?>{'directory': 'bad'},
    },
  };
  for (final MapEntry<String, Map<Object?, Object?> Function()> entry
      in malformed.entries) {
    test('rejects ${entry.key}', () async {
      final Map<String, Object?> response =
          await WorkspaceDemoServiceDispatcher(
            _FakeService(),
          ).dispatch(entry.value());
      final Map<Object?, Object?> error = response['error'] as Map;
      expect(response['ok'], isFalse);
      expect(error['code'], 'invalid_request');
      expect(error, isNot(contains('declaredFailureType')));
    });
  }

  test('emits declared failure type only for declared failures', () async {
    final WorkspaceDemoServiceDispatcher dispatcher =
        WorkspaceDemoServiceDispatcher(_ThrowingService(declared: true));
    final Map<String, Object?> response = await dispatcher.dispatch(valid);
    expect(
      (response['error'] as Map)['declaredFailureType'],
      'workspaceDemo.failure',
    );
  });

  test('contains unexpected service exceptions', () async {
    final WorkspaceDemoServiceDispatcher dispatcher =
        WorkspaceDemoServiceDispatcher(_ThrowingService(declared: false));
    final Map<String, Object?> response = await dispatcher.dispatch(valid);
    final Map<Object?, Object?> error = response['error'] as Map;
    expect(error['code'], 'internal_error');
    expect(error['message'], isNot(contains('secret')));
    expect(error, isNot(contains('declaredFailureType')));
  });
}

final class _ThrowingService implements WorkspaceDemoService {
  const _ThrowingService({required this.declared});
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
  Future<DirectoryListing> listDirectory(ResourceRef directory) async {
    return DirectoryListing(
      directory: directory,
      entries: <DirectoryEntry>[
        DirectoryEntry(
          resource: ResourceRef(uri: Uri.parse('file:///demo/readme.txt')),
          name: 'readme.txt',
          kind: DirectoryEntryKind.file,
        ),
      ],
    );
  }

  @override
  Future<TextFileContents> readTextFile(ResourceRef file) async {
    return TextFileContents(resource: file, text: 'text');
  }
}
