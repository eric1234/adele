import 'dart:io';

import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

void main() {
  test(
    'hosts the workspace backend through framed process IPC',
    () async {
      final String repository = Directory.current.parent.parent.path;
      final Directory artifacts = Directory(
        '$repository/.dart_tool/adele/integration/backend-host',
      )..createSync(recursive: true);
      final String dart = Platform.resolvedExecutable;
      final String dartaotruntime = '${File(dart).parent.path}/dartaotruntime';
      final File hostArtifact = File('${artifacts.path}/host.aot');
      final File pluginArtifact = File('${artifacts.path}/workspace.aot');
      await _compile(
        dart,
        '$repository/packages/plugin_backend_host/bin/adele_backend_host.dart',
        hostArtifact.path,
        repository,
      );
      await _compile(
        dart,
        '$repository/plugins/workspace_demo/packages/backend/bin/workspace_demo_backend.dart',
        pluginArtifact.path,
        repository,
      );
      final Directory developmentRoot = Directory('${artifacts.path}/demo')
        ..createSync(recursive: true);
      File(
        '${developmentRoot.path}/integration.txt',
      ).writeAsStringSync('backend host integration');

      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final PluginBackendConnection plugin = await host.startPlugin(
        pluginId: 'dev.adele.workspace-demo',
        artifactUri: pluginArtifact.uri,
        arguments: <String>[developmentRoot.path],
      );
      final Object? listing = await plugin.request(
        'workspaceDemo.listDirectory',
        <String, Object?>{
          'resource': <String, Object?>{
            'uri': developmentRoot.uri.toString(),
            'mediaType': null,
          },
        },
      );
      expect(listing, isA<Map<Object?, Object?>>());
      final Map<Object?, Object?> listingMap =
          listing! as Map<Object?, Object?>;
      final List<Object?> entries = listingMap['entries']! as List<Object?>;
      expect(
        (entries.single as Map<Object?, Object?>)['name'],
        'integration.txt',
      );
      await plugin.close();
      expect(host.isClosed, isFalse);
      await host.close();
      expect(host.isClosed, isTrue);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<void> _compile(
  String dart,
  String entrypoint,
  String output,
  String workingDirectory,
) async {
  final ProcessResult result = await Process.run(dart, <String>[
    'compile',
    'aot-snapshot',
    entrypoint,
    '-o',
    output,
  ], workingDirectory: workingDirectory);
  if (result.exitCode != 0) throw StateError(result.stderr.toString());
}
