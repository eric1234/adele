import 'dart:async';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:scripted_model_contract/scripted_model_contract.dart';
import 'package:test/test.dart';

final ProviderId _providerA1 = ProviderId('dev.adele.fixture.context-a-one');
final ProviderId _providerA2 = ProviderId('dev.adele.fixture.context-a-two');
final ProviderId _providerB1 = ProviderId('dev.adele.fixture.context-b-one');
final ProviderId _providerB2 = ProviderId('dev.adele.fixture.context-b-two');
const String _configurationB = 'configuration-b';
const String _pluginId = 'dev.adele.fixture.configuration-contexts';

void main() {
  test(
    'routes shared providers across two generation-bound contexts',
    () async {
      final String repository =
          Directory.current.parent.parent.parent.parent.path;
      final Directory artifacts = Directory(
        '$repository/.dart_tool/adele/integration/configuration-context-routing',
      )..createSync(recursive: true);
      final String dart = Platform.resolvedExecutable;
      final String runtime = '${File(dart).parent.path}/dartaotruntime';
      final File hostArtifact = File('${artifacts.path}/host.aot');
      final File pluginArtifact = File('${artifacts.path}/scripted.aot');
      await Future.wait<void>(<Future<void>>[
        _compile(
          dart,
          '$repository/packages/plugin_backend_host/bin/adele_backend_host.dart',
          hostArtifact.path,
          repository,
        ),
        _compile(
          dart,
          '$repository/plugins/scripted_model/packages/backend/bin/'
          'configuration_context_scripted_model_backend.dart',
          pluginArtifact.path,
          repository,
        ),
      ]);
      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: runtime,
        hostArtifactPath: hostArtifact.path,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final CapabilityRegistry registry = CapabilityRegistry();
      final PluginBackendConnection generationA = await host.startPlugin(
        pluginId: _pluginId,
        artifactUri: pluginArtifact.uri,
      );
      final ConfigurationContextId contextA =
          generationA.defaultConfigurationContext;
      final ConfigurationContextId contextB = generationA.configurationContext(
        _configurationB,
      );
      final PluginCapabilityActivation activationA = await _register(
        generationA,
        registry,
        contextA,
        contextB,
      );
      final ProviderBinding bindingA1 = _binding(registry, _providerA1);
      final ProviderBinding bindingA2 = _binding(registry, _providerA2);
      final ProviderBinding bindingB1 = _binding(registry, _providerB1);
      final ProviderBinding bindingB2 = _binding(registry, _providerB2);
      final ScriptedModelFixtureServiceClient clientA1 = _client(bindingA1);
      final ScriptedModelFixtureServiceClient clientA2 = _client(bindingA2);
      final ScriptedModelFixtureServiceClient clientB1 = _client(bindingB1);
      final ScriptedModelFixtureServiceClient clientB2 = _client(bindingB2);

      expect(_providerA1, isNot(_providerA2));
      expect(_providerB1, isNot(_providerB2));
      expect(
        (await clientA1.invoke(_ordinaryRequest(_configurationB))).content,
        startsWith('[configuration-a]'),
      );
      expect(
        (await clientA2.invoke(_ordinaryRequest(_configurationB))).content,
        startsWith('[configuration-a]'),
      );
      expect(
        (await clientB1.invoke(_ordinaryRequest('default'))).content,
        startsWith('[configuration-b]'),
      );
      expect(
        (await clientB2.invoke(_ordinaryRequest('default'))).content,
        startsWith('[configuration-b]'),
      );

      final List<ScriptedModelStreamItem> streamA = await clientA1
          .invokeStream(_ordinaryRequest(_configurationB))
          .toList();
      final List<ScriptedModelStreamItem> streamB = await clientB1
          .invokeStream(_ordinaryRequest('default'))
          .toList();
      expect(streamA.first.text, startsWith('[configuration-a]'));
      expect(streamB.first.text, startsWith('[configuration-b]'));

      await clientA1.resetStreamProbe();
      await clientB1.resetStreamProbe();
      final _PausedStream pausedA = await _pauseAfterFirst(clientA1);
      final _PausedStream pausedB = await _pauseAfterFirst(clientB1);
      expect((await clientA2.streamProbe()).advanced, 1);
      expect((await clientB2.streamProbe()).advanced, 1);
      await pausedA.subscription.cancel().timeout(const Duration(seconds: 2));
      expect((await clientA2.streamProbe()).cancellations, 1);
      expect((await clientA2.streamProbe()).active, 0);
      expect((await clientB2.streamProbe()).cancellations, 0);
      expect((await clientB2.streamProbe()).active, 1);
      pausedB.subscription.resume();
      while (pausedB.sequences.length < 3) {
        await Future<void>.delayed(Duration.zero);
      }
      await pausedB.subscription.cancel().timeout(const Duration(seconds: 2));
      expect((await clientB2.streamProbe()).cancellations, 1);

      final AdeleStreamChannel retainedChannel = bindingA1.streamChannel;
      await activationA.close();
      final PluginBackendConnection generationB = await host.startPlugin(
        pluginId: _pluginId,
        artifactUri: pluginArtifact.uri,
      );
      expect(() => generationB.channelFor(contextA), throwsArgumentError);
      final PluginCapabilityActivation activationB = await _register(
        generationB,
        registry,
        generationB.defaultConfigurationContext,
        generationB.configurationContext(_configurationB),
      );
      expect(
        () => bindingA1.streamChannel,
        throwsA(isA<ProviderUnavailable>()),
      );
      expect(
        () => bindingB1.streamChannel,
        throwsA(isA<ProviderUnavailable>()),
      );
      await expectLater(
        ScriptedModelFixtureServiceClient(
          retainedChannel,
        ).invoke(_ordinaryRequest('stale')),
        throwsA(isA<PluginConnectionClosed>()),
      );
      expect(
        (await _client(
          _binding(registry, _providerB2),
        ).invoke(_ordinaryRequest('fresh'))).content,
        startsWith('[configuration-b]'),
      );

      await activationB.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<PluginCapabilityActivation> _register(
  PluginBackendConnection connection,
  CapabilityRegistry registry,
  ConfigurationContextId contextA,
  ConfigurationContextId contextB,
) => PluginCapabilityActivation.register(
  connection: connection,
  registry: registry,
  exposures: <PluginCapabilityExposure>[
    PluginCapabilityExposure(
      provider: _descriptor(_providerA1, connection.pluginId),
      configurationContext: contextA,
    ),
    PluginCapabilityExposure(
      provider: _descriptor(_providerA2, connection.pluginId),
      configurationContext: contextA,
    ),
    PluginCapabilityExposure(
      provider: _descriptor(_providerB1, connection.pluginId),
      configurationContext: contextB,
    ),
    PluginCapabilityExposure(
      provider: _descriptor(_providerB2, connection.pluginId),
      configurationContext: contextB,
    ),
  ],
);

ProviderBinding _binding(CapabilityRegistry registry, ProviderId id) =>
    registry.resolve(scriptedModelFixtureCapability, providerId: id);

ScriptedModelFixtureServiceClient _client(ProviderBinding binding) =>
    ScriptedModelFixtureServiceClient(binding.streamChannel);

ProviderDescriptor _descriptor(ProviderId id, String pluginId) =>
    ProviderDescriptor(
      id: id,
      capability: scriptedModelFixtureCapability,
      pluginId: pluginId,
      displayName: id.value,
      serviceId: scriptedModelFixtureServiceId,
    );

ScriptedModelRequest _ordinaryRequest(String semanticSpoof) =>
    ScriptedModelRequest(
      messages: <ScriptedModelMessage>[
        ScriptedModelMessage(
          role: ScriptedModelMessageRole.user,
          content: semanticSpoof,
          toolCallId: null,
          toolOutcome: null,
          toolProposal: null,
        ),
      ],
      tools: const <ScriptedToolDefinition>[
        ScriptedToolDefinition(
          name: 'inspect_resource',
          description: 'fixture',
          argumentsSchema: <String, Object?>{},
        ),
      ],
    );

ScriptedModelRequest _longRequest() => const ScriptedModelRequest(
  messages: <ScriptedModelMessage>[
    ScriptedModelMessage(
      role: ScriptedModelMessageRole.user,
      content: 'fixture:long-stream',
      toolCallId: null,
      toolOutcome: null,
      toolProposal: null,
    ),
  ],
  tools: <ScriptedToolDefinition>[],
);

Future<_PausedStream> _pauseAfterFirst(
  ScriptedModelFixtureServiceClient client,
) async {
  final List<int> sequences = <int>[];
  final Completer<void> first = Completer<void>();
  late final StreamSubscription<ScriptedModelStreamItem> subscription;
  subscription = client.invokeStream(_longRequest()).listen((item) {
    sequences.add(item.sequence!);
    if (!first.isCompleted) {
      subscription.pause();
      first.complete();
    }
  });
  await first.future;
  return _PausedStream(subscription, sequences);
}

final class _PausedStream {
  const _PausedStream(this.subscription, this.sequences);

  final StreamSubscription<ScriptedModelStreamItem> subscription;
  final List<int> sequences;
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
