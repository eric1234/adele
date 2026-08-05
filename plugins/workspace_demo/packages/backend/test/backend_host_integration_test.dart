import 'dart:io';

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';
import 'package:workspace_demo_contract/workspace_demo_contract.dart';

void main() {
  test('keeps the internal runtime outside production dependencies', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final String dependencies = pubspec
        .split('dev_dependencies:')
        .first
        .split('dependencies:')
        .last;
    final String devDependencies = pubspec.split('dev_dependencies:').last;

    expect(dependencies, isNot(contains('plugin_runtime:')));
    expect(devDependencies, contains('plugin_runtime:'));
  });

  test(
    'hosts the typed workspace backend through framed process IPC',
    () async {
      final String repository =
          Directory.current.parent.parent.parent.parent.path;
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
      final DirectoryListing listing = await WorkspaceDemoServiceClient(
        plugin,
      ).listDirectory(ResourceRef(uri: developmentRoot.uri));
      expect(listing.entries.single.name, 'integration.txt');
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
