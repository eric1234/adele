import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:development_source_backend/development_source_backend.dart';
import 'package:development_source_contract/development_source_contract.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

void main() {
  late String repository;
  late String dartaotruntime;
  late File hostArtifact;
  late File pluginArtifact;

  setUpAll(() async {
    repository = Directory.current.parent.parent.parent.parent.path;
    final Directory artifacts = Directory(
      '$repository/.dart_tool/adele/integration/development-source',
    )..createSync(recursive: true);
    final String dart = Platform.resolvedExecutable;
    dartaotruntime = '${File(dart).parent.path}/dartaotruntime';
    hostArtifact = File('${artifacts.path}/host.aot');
    pluginArtifact = File('${artifacts.path}/development-source.aot');
    await Future.wait<void>(<Future<void>>[
      _compile(
        dart,
        '$repository/packages/plugin_backend_host/bin/adele_backend_host.dart',
        hostArtifact.path,
        repository,
      ),
      _compile(
        dart,
        '$repository/plugins/development_source/packages/backend/bin/'
        'development_source_backend.dart',
        pluginArtifact.path,
        repository,
      ),
    ]);
  });

  test(
    'reads and searches the configured root through an exact AOT binding',
    () async {
      final Directory rootA = await Directory.systemTemp.createTemp(
        'adele-development-source-a-',
      );
      final Directory rootB = await Directory.systemTemp.createTemp(
        'adele-development-source-b-',
      );
      addTearDown(() => rootA.delete(recursive: true));
      addTearDown(() => rootB.delete(recursive: true));
      await Directory('${rootA.path}/lib').create();
      await File(
        '${rootA.path}/lib/feature.dart',
      ).writeAsString('const generation = "alpha";\n// source-hit\n');
      await File(
        '${rootB.path}/replacement.dart',
      ).writeAsString('const generation = "beta";\n');

      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final CapabilityRegistry registry = CapabilityRegistry();
      final PluginBackendConnection generationA = await host.startPlugin(
        pluginId: developmentSourcePluginId,
        artifactUri: pluginArtifact.uri,
        arguments: <String>[rootA.path],
      );
      final PluginCapabilityActivation activationA = await _register(
        generationA,
        registry,
      );
      final ProviderBinding bindingA = registry.resolve(
        developmentSourceCapability,
        providerId: ProviderId(localDevelopmentSourceProviderId),
      );
      final DevelopmentSourceServiceClient clientA =
          DevelopmentSourceServiceClient(bindingA.requestChannel);

      final DevelopmentSourceTextFile file = await clientA.readTextFile(
        'lib/feature.dart',
      );
      expect(file.relativePath, 'lib/feature.dart');
      expect(file.text, contains('alpha'));
      final DevelopmentSourceSearchResult search = await clientA.searchText(
        'source-hit',
      );
      expect(search.matches.single.relativePath, 'lib/feature.dart');
      expect(search.matches.single.lineNumber, 2);

      await activationA.close();
      final PluginBackendConnection generationB = await host.startPlugin(
        pluginId: developmentSourcePluginId,
        artifactUri: pluginArtifact.uri,
        arguments: <String>[rootB.path],
      );
      final PluginCapabilityActivation activationB = await _register(
        generationB,
        registry,
      );
      expect(
        () => bindingA.requestChannel,
        throwsA(isA<ProviderUnavailable>()),
      );
      await expectLater(
        clientA.readTextFile('lib/feature.dart'),
        throwsA(isA<PluginConnectionClosed>()),
      );
      final DevelopmentSourceServiceClient clientB =
          DevelopmentSourceServiceClient(
            registry
                .resolve(
                  developmentSourceCapability,
                  providerId: ProviderId(localDevelopmentSourceProviderId),
                )
                .requestChannel,
          );
      expect(
        (await clientB.readTextFile('replacement.dart')).text,
        contains('beta'),
      );
      await expectLater(
        clientB.readTextFile('lib/feature.dart'),
        throwsA(
          isA<DevelopmentSourceFailure>().having(
            (DevelopmentSourceFailure failure) => failure.code,
            'code',
            'not_found',
          ),
        ),
      );

      await activationB.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Future<PluginCapabilityActivation> _register(
  PluginBackendConnection connection,
  CapabilityRegistry registry,
) => PluginCapabilityActivation.register(
  connection: connection,
  registry: registry,
  exposures: <PluginCapabilityExposure>[
    PluginCapabilityExposure(
      provider: ProviderDescriptor(
        id: ProviderId(localDevelopmentSourceProviderId),
        capability: developmentSourceCapability,
        pluginId: connection.pluginId,
        displayName: 'Local Development Source',
        serviceId: developmentSourceServiceId,
      ),
      configurationContext: connection.defaultConfigurationContext,
    ),
  ],
);

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
