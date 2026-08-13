import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

void main() {
  test(
    'publishes only ready connections and retires before shutdown',
    () async {
      final _FakeHost fake = _FakeHost.create();
      addTearDown(fake.dispose);
      final PluginBackendHost host = await fake.start();
      final CapabilityRegistry registry = CapabilityRegistry();
      final CapabilityKey capability = CapabilityKey(
        id: CapabilityId('dev.adele.resource.inspect'),
        majorVersion: 1,
      );
      expect(registry.providersFor(capability), isEmpty);
      final PluginBackendConnection connection = await host.startPlugin(
        pluginId: 'dev.adele.provider',
        artifactUri: Uri.file('/unused.aot'),
      );
      final PluginCapabilityActivation activation =
          await PluginCapabilityActivation.register(
            connection: connection,
            registry: registry,
            providers: <ProviderDescriptor>[
              _provider(capability, 'dev.adele.provider.inspector'),
            ],
          );
      expect(registry.providersFor(capability), hasLength(1));

      final ProviderBinding binding = registry.resolve(capability);
      await activation.close();
      expect(registry.providersFor(capability), isEmpty);
      expect(() => binding.requestChannel, throwsA(isA<ProviderUnavailable>()));
      await host.close();
    },
  );

  test(
    'backend failure retires all registrations for the generation',
    () async {
      final _FakeHost fake = _FakeHost.create(failOnRequest: true);
      addTearDown(fake.dispose);
      final PluginBackendHost host = await fake.start();
      final CapabilityRegistry registry = CapabilityRegistry();
      final CapabilityKey first = CapabilityKey(
        id: CapabilityId('dev.adele.resource.inspect'),
        majorVersion: 1,
      );
      final CapabilityKey second = CapabilityKey(
        id: CapabilityId('dev.adele.resource.summarize'),
        majorVersion: 1,
      );
      final PluginBackendConnection connection = await host.startPlugin(
        pluginId: 'dev.adele.provider',
        artifactUri: Uri.file('/unused.aot'),
      );
      await PluginCapabilityActivation.register(
        connection: connection,
        registry: registry,
        providers: <ProviderDescriptor>[
          _provider(first, 'dev.adele.provider.inspector'),
          _provider(second, 'dev.adele.provider.summarizer'),
        ],
      );
      await expectLater(
        connection.request('crash', const <String, Object?>{}),
        throwsA(isA<PluginRemoteFailure>()),
      );
      await connection.terminated;
      await Future<void>.delayed(Duration.zero);
      expect(registry.providersFor(first), isEmpty);
      expect(registry.providersFor(second), isEmpty);
      await host.close();
    },
  );

  test('partial activation mismatch rolls back previous providers', () async {
    final _FakeHost fake = _FakeHost.create();
    addTearDown(fake.dispose);
    final PluginBackendHost host = await fake.start();
    final CapabilityRegistry registry = CapabilityRegistry();
    final CapabilityKey capability = CapabilityKey(
      id: CapabilityId('dev.adele.resource.inspect'),
      majorVersion: 1,
    );
    final PluginBackendConnection connection = await host.startPlugin(
      pluginId: 'dev.adele.provider',
      artifactUri: Uri.file('/unused.aot'),
    );
    await expectLater(
      PluginCapabilityActivation.register(
        connection: connection,
        registry: registry,
        providers: <ProviderDescriptor>[
          _provider(capability, 'dev.adele.provider.first'),
          _provider(
            capability,
            'dev.adele.provider.second',
            pluginId: 'dev.adele.other',
          ),
        ],
      ),
      throwsA(isA<InvalidProviderRegistration>()),
    );
    expect(registry.providersFor(capability), isEmpty);
    await connection.close();
    await host.close();
  });
}

ProviderDescriptor _provider(
  CapabilityKey capability,
  String id, {
  String pluginId = 'dev.adele.provider',
}) => ProviderDescriptor(
  id: ProviderId(id),
  capability: capability,
  pluginId: pluginId,
  displayName: id,
  serviceId: 'resourceInspector',
);

final class _FakeHost {
  _FakeHost._(this.directory, this.script);

  factory _FakeHost.create({bool failOnRequest = false}) {
    final Directory directory = Directory(
      '${Directory.current.path}/.dart_tool/capability-runtime/'
      '${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    final File script = File('${directory.path}/host.dart')
      ..writeAsStringSync('''
import 'dart:io';
import 'package:plugin_runtime/plugin_runtime.dart';
void main() {
  stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostHello'}));
  final decoder = BackendHostFrameDecoder();
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      if (message['kind'] == 'startPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'stopPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginStopped', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'request') {
        ${failOnRequest ? "stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginFailed', 'pluginId': message['pluginId'], 'requestIds': [message['requestId']], 'error': {'code': 'plugin_exited', 'message': 'failed'}}));" : "stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'response', 'requestId': message['requestId'], 'pluginId': message['pluginId'], 'ok': true, 'payload': {}}));"}
      } else if (message['kind'] == 'shutdownHost') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'hostStopped', 'requestId': message['requestId']}));
        exit(0);
      }
    }
  });
}
''');
    return _FakeHost._(directory, script);
  }

  final Directory directory;
  final File script;

  Future<PluginBackendHost> start() async {
    final String dart = Platform.resolvedExecutable;
    final String dartaotruntime = '${File(dart).parent.path}/dartaotruntime';
    final File snapshot = File('${directory.path}/host.aot');
    final ProcessResult snapshotResult = await Process.run(dart, <String>[
      'compile',
      'aot-snapshot',
      script.path,
      '-o',
      snapshot.path,
    ], workingDirectory: Directory.current.path);
    if (snapshotResult.exitCode != 0) {
      throw StateError(snapshotResult.stderr.toString());
    }
    return PluginBackendHost.start(
      dartaotruntimeExecutable: dartaotruntime,
      hostArtifactPath: snapshot.path,
    );
  }

  Future<void> dispose() async {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}
