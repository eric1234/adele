import 'dart:io';

import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory artifacts;
  late File hostArtifact;
  late File pluginArtifact;
  late String dartaotruntime;

  setUpAll(() async {
    final String repository = Directory.current.parent.parent.path;
    artifacts = Directory(
      '$repository/.dart_tool/adele/phase1/termination-test',
    )..createSync(recursive: true);
    hostArtifact = File('${artifacts.path}/host.aot');
    pluginArtifact = File('${artifacts.path}/plugin.aot');
    final String dart = Platform.resolvedExecutable;
    dartaotruntime = '${File(dart).parent.path}/dartaotruntime';
    await _compile(
      dart,
      '$repository/packages/plugin_backend_host/bin/adele_backend_host.dart',
      hostArtifact.path,
      repository,
    );
    await _compile(
      dart,
      '$repository/tools/experiments/phase1/crashing_backend.dart',
      pluginArtifact.path,
      repository,
    );
  });

  test(
    'fails pending request and restarts same plugin ID after exit',
    () async {
      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final PluginBackendConnection first = await host.startPlugin(
        pluginId: 'crashing',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      await expectLater(
        first.request('crash', const <String, Object?>{}),
        throwsA(
          isA<PluginRemoteFailure>().having(
            (PluginRemoteFailure value) => value.code,
            'code',
            'plugin_exited',
          ),
        ),
      );
      expect(first.isClosed, isTrue);
      await expectLater(
        first.request('after-exit', const <String, Object?>{}),
        throwsA(isA<PluginConnectionClosed>()),
      );
      final PluginBackendConnection restarted = await host.startPlugin(
        pluginId: 'crashing',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      expect(
        await restarted.request('ping', const <String, Object?>{}),
        <String, Object?>{'alive': true},
      );
      await restarted.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'removes plugin that exits without pending requests',
    () async {
      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final PluginBackendConnection first = await host.startPlugin(
        pluginId: 'crashing',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['exit-immediately'],
      );
      for (int attempt = 0; attempt < 50 && !first.isClosed; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(first.isClosed, isTrue);
      final PluginBackendConnection restarted = await host.startPlugin(
        pluginId: 'crashing',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      await restarted.close();
      await host.close();
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
