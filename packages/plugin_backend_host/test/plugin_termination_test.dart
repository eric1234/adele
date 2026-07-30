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
      '$repository/.dart_tool/adele/development-runtime/termination-test',
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
      '$repository/packages/plugin_backend_host/test/fixtures/crashing_backend.dart',
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

  test(
    'fails pending request when plugin is stopped and keeps host usable',
    () async {
      final PluginBackendHost host = await _startHost(
        dartaotruntime,
        hostArtifact,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final PluginBackendConnection plugin = await host.startPlugin(
        pluginId: 'stoppable',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      final Future<Object?> pending = plugin.request(
        'pending',
        const <String, Object?>{},
      );
      final Future<void> expectation = expectLater(
        pending.timeout(const Duration(seconds: 5)),
        throwsA(isA<PluginConnectionClosed>()),
      );
      await plugin.close();
      await expectation;
      final PluginBackendConnection restarted = await host.startPlugin(
        pluginId: 'stoppable',
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
    'kills plugin that acknowledges shutdown without exiting and restarts it',
    () async {
      final PluginBackendHost host = await _startHost(
        dartaotruntime,
        hostArtifact,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final PluginBackendConnection hanging = await host.startPlugin(
        pluginId: 'hanging',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['acknowledge-hang'],
      );
      await hanging.close().timeout(const Duration(seconds: 6));
      final PluginBackendConnection restarted = await host.startPlugin(
        pluginId: 'hanging',
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
    'contains oversized responses and keeps plugin and host usable',
    () async {
      final PluginBackendHost host = await _startHost(
        dartaotruntime,
        hostArtifact,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final PluginBackendConnection plugin = await host.startPlugin(
        pluginId: 'large',
        artifactUri: pluginArtifact.uri,
        arguments: const <String>['wait'],
      );
      final Object? below = await plugin.request(
        'large-below',
        const <String, Object?>{},
      );
      expect((below! as String).length, 8 * 1024 * 1024 - 2048);
      await expectLater(
        plugin.request('large-above', const <String, Object?>{}),
        throwsA(
          isA<PluginRemoteFailure>().having(
            (PluginRemoteFailure value) => value.code,
            'code',
            'response_too_large',
          ),
        ),
      );
      expect(
        await plugin.request('ping', const <String, Object?>{}),
        <String, Object?>{'alive': true},
      );
      await plugin.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<PluginBackendHost> _startHost(String dartaotruntime, File hostArtifact) {
  return PluginBackendHost.start(
    dartaotruntimeExecutable: dartaotruntime,
    hostArtifactPath: hostArtifact.path,
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
