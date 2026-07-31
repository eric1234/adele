import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:test/test.dart';
import 'package:workspace_demo_backend/workspace_demo_backend.dart';
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
