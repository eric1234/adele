import 'dart:async';
import 'dart:isolate';

import 'package:adele_desktop/phase1/workspace_demo/workspace_demo_proxy.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:workspace_demo_contract/workspace_demo_contract.dart';

void main() {
  test('reconstructs typed nested contract values', () async {
    final ReceivePort commands = ReceivePort();
    final ReceivePort responses = ReceivePort();
    final PluginBackendConnection connection = PluginBackendConnection.testPeer(
      commandPort: commands.sendPort,
      responses: responses,
    );
    final WorkspaceDemoProxy proxy = WorkspaceDemoProxy(connection);
    final StreamSubscription<Object?> subscription = commands.listen((
      Object? raw,
    ) {
      final Map<Object?, Object?> request = (raw as Map)
          .cast<Object?, Object?>();
      responses.sendPort.send(<String, Object?>{
        'kind': 'response',
        'requestId': request['requestId'],
        'ok': true,
        'payload': <String, Object?>{
          'directory': <String, Object?>{
            'uri': 'file:///demo',
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
        },
      });
    });

    final DirectoryListing listing = await proxy.listDirectory(
      ResourceRef(uri: Uri.parse('file:///demo')),
    );
    expect(listing.entries.single.name, 'readme.txt');
    expect(listing.entries.single.kind, DirectoryEntryKind.file);
    expect(listing.entries.single.resource.mediaType, 'text/plain');
    await connection.close(graceful: false);
    await subscription.cancel();
    commands.close();
  });
}
