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
            exposures: <PluginCapabilityExposure>[
              PluginCapabilityExposure(
                provider: _provider(capability, 'dev.adele.provider.inspector'),
                configurationContext: connection.defaultConfigurationContext,
              ),
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
        exposures: <PluginCapabilityExposure>[
          PluginCapabilityExposure(
            provider: _provider(first, 'dev.adele.provider.inspector'),
            configurationContext: connection.defaultConfigurationContext,
          ),
          PluginCapabilityExposure(
            provider: _provider(second, 'dev.adele.provider.summarizer'),
            configurationContext: connection.defaultConfigurationContext,
          ),
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

  test('bindings own explicit shared configuration contexts', () async {
    final _FakeHost fake = _FakeHost.create(contextEcho: true);
    addTearDown(fake.dispose);
    final PluginBackendHost host = await fake.start();
    final CapabilityRegistry registry = CapabilityRegistry();
    final CapabilityKey capability = CapabilityKey(
      id: CapabilityId('dev.adele.resource.inspect'),
      majorVersion: 1,
    );
    final ProviderId contextAFirstId = ProviderId(
      'dev.adele.provider.context-a-first',
    );
    final ProviderId contextASecondId = ProviderId(
      'dev.adele.provider.context-a-second',
    );
    final ProviderId contextBId = ProviderId(
      'dev.adele.provider.context-b-first',
    );
    final PluginBackendConnection connection = await host.startPlugin(
      pluginId: 'dev.adele.provider',
      artifactUri: Uri.file('/unused.aot'),
    );
    final PluginCapabilityActivation activation =
        await PluginCapabilityActivation.register(
          connection: connection,
          registry: registry,
          exposures: <PluginCapabilityExposure>[
            PluginCapabilityExposure(
              provider: _provider(capability, contextAFirstId.value),
              configurationContext: connection.defaultConfigurationContext,
            ),
            PluginCapabilityExposure(
              provider: _provider(
                capability,
                contextASecondId.value,
                serviceId: 'resourceSummarizer',
              ),
              configurationContext: connection.defaultConfigurationContext,
            ),
            PluginCapabilityExposure(
              provider: _provider(capability, contextBId.value),
              configurationContext: connection.configurationContext(
                'configuration-b',
              ),
            ),
          ],
        );
    final Map<String, Object?> semanticPayload = <String, Object?>{
      'configurationContext': 'configuration-b',
      'serviceId': 'spoofedService',
      'value': 'same semantic request',
    };
    final ProviderBinding contextAFirst = registry.resolve(
      capability,
      providerId: contextAFirstId,
    );
    final ProviderBinding contextASecond = registry.resolve(
      capability,
      providerId: contextASecondId,
    );
    final ProviderBinding contextB = registry.resolve(
      capability,
      providerId: contextBId,
    );

    final Object? firstResult = await contextAFirst.requestChannel.request(
      'resourceInspector.inspect',
      semanticPayload,
    );
    final Object? secondResult = await contextASecond.requestChannel.request(
      'resourceInspector.inspect',
      semanticPayload,
    );
    final Object? contextBResult = await contextB.requestChannel.request(
      'resourceInspector.inspect',
      semanticPayload,
    );
    expect(firstResult, isA<Map<String, Object?>>());
    expect(secondResult, isA<Map<String, Object?>>());
    expect(contextBResult, isA<Map<String, Object?>>());
    final Map<String, Object?> firstMap = firstResult! as Map<String, Object?>;
    final Map<String, Object?> secondMap =
        secondResult! as Map<String, Object?>;
    final Map<String, Object?> contextBMap =
        contextBResult! as Map<String, Object?>;
    expect(firstMap['configurationContext'], secondMap['configurationContext']);
    expect(firstMap['serviceId'], 'resourceInspector');
    expect(secondMap['serviceId'], 'resourceSummarizer');
    expect(
      firstMap['configurationContext'],
      isNot(contextBMap['configurationContext']),
    );
    expect(firstMap['payload'], semanticPayload);
    expect(
      await contextB.streamChannel
          .stream('resourceInspector.watch', semanticPayload)
          .toList(),
      <Object?>[contextBResult],
    );

    await activation.close();
    await host.close();
  });

  test('configuration contexts cannot cross plugin generations', () async {
    final _FakeHost fake = _FakeHost.create();
    addTearDown(fake.dispose);
    final PluginBackendHost host = await fake.start();
    final PluginBackendConnection first = await host.startPlugin(
      pluginId: 'dev.adele.provider.first',
      artifactUri: Uri.file('/unused.aot'),
    );
    final PluginBackendConnection second = await host.startPlugin(
      pluginId: 'dev.adele.provider.second',
      artifactUri: Uri.file('/unused.aot'),
    );

    expect(
      () => second.channelFor(
        first.defaultConfigurationContext,
        'resourceInspector',
      ),
      throwsArgumentError,
    );

    await first.close();
    await second.close();
    await host.close();
  });

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
        exposures: <PluginCapabilityExposure>[
          PluginCapabilityExposure(
            provider: _provider(capability, 'dev.adele.provider.first'),
            configurationContext: connection.defaultConfigurationContext,
          ),
          PluginCapabilityExposure(
            provider: _provider(
              capability,
              'dev.adele.provider.second',
              pluginId: 'dev.adele.other',
            ),
            configurationContext: connection.defaultConfigurationContext,
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
  String serviceId = 'resourceInspector',
}) => ProviderDescriptor(
  id: ProviderId(id),
  capability: capability,
  pluginId: pluginId,
  displayName: id,
  serviceId: serviceId,
);

final class _FakeHost {
  _FakeHost._(this.directory, this.script);

  factory _FakeHost.create({
    bool failOnRequest = false,
    bool contextEcho = false,
  }) {
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
  final streams = <int, Map<String, Object?>>{};
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      if (message['kind'] == 'startPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginReady', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'stopPlugin') {
        stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginStopped', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
      } else if (message['kind'] == 'request') {
        ${failOnRequest
          ? "stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'pluginFailed', 'pluginId': message['pluginId'], 'requestIds': [message['requestId']], 'error': {'code': 'plugin_exited', 'message': 'failed'}}));"
          : contextEcho
          ? "stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'response', 'requestId': message['requestId'], 'pluginId': message['pluginId'], 'ok': true, 'payload': {'configurationContext': message['configurationContext'], 'serviceId': message['serviceId'], 'payload': message['payload']}}));"
          : "stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'response', 'requestId': message['requestId'], 'pluginId': message['pluginId'], 'ok': true, 'payload': {}}));"}
      } else if (message['kind'] == 'streamOpen') {
        streams[message['requestId'] as int] = message;
      } else if (message['kind'] == 'streamCredit') {
        final open = streams.remove(message['requestId']);
        if (open != null) {
          stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'streamItem', 'requestId': message['requestId'], 'pluginId': message['pluginId'], 'payload': {'configurationContext': open['configurationContext'], 'serviceId': open['serviceId'], 'payload': open['payload']}}));
          stdout.add(encodeBackendHostFrame({'protocolVersion': backendHostProtocolVersion, 'kind': 'streamDone', 'requestId': message['requestId'], 'pluginId': message['pluginId']}));
        }
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
