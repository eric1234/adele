import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/development/agent/agent_capability_adapters.dart';
import 'package:adele_desktop/development/agent/development_agent_support.dart';
import 'package:adele_desktop/development/agent/development_source_tools.dart';
import 'package:adele_desktop/development/agent/simple_tool_loop_strategy.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:development_source_contract/development_source_contract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

void main() {
  final bool enabled =
      Platform.environment['ADELE_OPENAI_CHATGPT_LIVE_TEST'] == '1';
  late String repository;
  late String dartaotruntime;
  late File hostArtifact;
  late File openAiArtifact;
  late File developmentSourceArtifact;

  setUpAll(() async {
    if (!enabled) return;
    repository = Directory.current.parent.path;
    final Directory artifacts = Directory(
      '$repository/.dart_tool/adele/integration/phase-iv-b-source-live',
    )..createSync(recursive: true);
    final String dart = _dartExecutable();
    dartaotruntime =
        '${File(dart).parent.path}/${Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime'}';
    hostArtifact = File('${artifacts.path}/host.aot');
    openAiArtifact = File('${artifacts.path}/openai.aot');
    developmentSourceArtifact = File(
      '${artifacts.path}/development-source.aot',
    );
    await Future.wait(<Future<void>>[
      _compile(
        dart,
        '$repository/packages/plugin_backend_host/bin/adele_backend_host.dart',
        hostArtifact.path,
        repository,
      ),
      _compile(
        dart,
        '$repository/plugins/openai/packages/backend/bin/openai_model_provider_backend.dart',
        openAiArtifact.path,
        repository,
      ),
      _compile(
        dart,
        '$repository/plugins/development_source/packages/backend/bin/development_source_backend.dart',
        developmentSourceArtifact.path,
        repository,
      ),
    ]);
  });

  test(
    'experimental ChatGPT searches and reads the real ADELE strategy source',
    () async {
      const String strategyPath =
          'app/lib/development/agent/simple_tool_loop_strategy.dart';
      final String credentialPath = _requiredEnvironment(
        'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE',
      );
      final Map<String, String> environment = <String, String>{
        'OPENAI_API_KEY': 'unused-live-source-coding-key',
        'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': credentialPath,
      };
      for (final String name in <String>[
        'ADELE_OPENAI_CHATGPT_CLIENT_ID',
        'ADELE_OPENAI_CHATGPT_INSTANCE_ID',
        'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER',
        'ADELE_OPENAI_CHATGPT_REDIRECT_URI',
        'ADELE_OPENAI_CHATGPT_ENDPOINT',
      ]) {
        final String? value = Platform.environment[name];
        if (value != null && value.trim().isNotEmpty) environment[name] = value;
      }
      if (!environment.containsKey('ADELE_OPENAI_CHATGPT_CLIENT_ID')) {
        environment['ADELE_OPENAI_CHATGPT_EXPERIMENTAL_CODEX_CLIENT'] = '1';
      }
      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
        environment: environment,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final CapabilityRegistry registry = CapabilityRegistry();
      final _Activation model = await _startProvider(
        host: host,
        registry: registry,
        pluginId: 'dev.adele.openai',
        artifact: openAiArtifact,
        descriptor: ProviderDescriptor(
          id: ProviderId('dev.adele.openai.chatgpt-experimental'),
          capability: modelProviderCapability,
          pluginId: 'dev.adele.openai',
          displayName: 'Experimental ChatGPT',
          serviceId: modelProviderServiceId,
        ),
        configurationContext: 'chatgpt-experimental',
      );
      addTearDown(model.close);
      final _Activation source = await _startProvider(
        host: host,
        registry: registry,
        pluginId: 'dev.adele.plugin.development-source',
        artifact: developmentSourceArtifact,
        descriptor: ProviderDescriptor(
          id: ProviderId('dev.adele.development-source.local'),
          capability: developmentSourceCapability,
          pluginId: 'dev.adele.plugin.development-source',
          displayName: 'ADELE Development Source',
          serviceId: developmentSourceServiceId,
        ),
        arguments: <String>[repository],
      );
      addTearDown(source.close);
      final ModelProviderCapabilityAdapter modelAdapter =
          ModelProviderCapabilityAdapter(
            registry.resolve(
              modelProviderCapability,
              providerId: ProviderId('dev.adele.openai.chatgpt-experimental'),
            ),
            selectedModel:
                Platform.environment['ADELE_OPENAI_CHATGPT_TEST_MODEL'] ??
                'gpt-5.4',
          );
      final ProviderBinding sourceBinding = registry.resolve(
        developmentSourceCapability,
      );
      final DevelopmentSourceSearchToolExecutable searchTool =
          DevelopmentSourceSearchToolExecutable(sourceBinding);
      final DevelopmentSourceReadToolExecutable readTool =
          DevelopmentSourceReadToolExecutable(sourceBinding);
      final DevelopmentSessionHistory session =
          DevelopmentSessionHistory(
            SessionId('session-chatgpt-source-live'),
          )..append(
            UserSessionMessage(
              'Use the provided source tools. Locate the file that declares DevelopmentToolLoopStrategy, read that file, and report the exact root-relative path plus the default maximum model invocation count. You must inspect the source rather than answer from memory.',
            ),
          );
      final AgentRun run = AgentRun(
        id: RunId('run-chatgpt-source-live'),
        sessionId: session.id,
      );
      final DevelopmentToolLoopStrategy strategy = DevelopmentToolLoopStrategy(
        run: run,
        session: session,
        contextAssembler: const DevelopmentContextAssembler(
          instructions:
              'You must call search_source_text for "final class DevelopmentToolLoopStrategy", then call read_source_file with the returned path before answering. Report the path and the default maxModelInvocations value from the file.',
        ),
        model: modelAdapter,
        toolCatalog: ToolCatalog()
          ..register(searchTool.registration)
          ..register(readTool.registration),
        policy: const DevelopmentToolPolicy(ToolPolicyDecision.allow),
      );

      await strategy.start();

      expect(run.state, RunState.completed);
      expect(searchTool.invocationCount, greaterThanOrEqualTo(1));
      expect(readTool.invocationCount, greaterThanOrEqualTo(1));
      final String answer =
          (session.snapshot().entries.last as AssistantSessionMessage).content;
      expect(answer.trim(), isNotEmpty);
      expect(answer, contains(strategyPath));
      expect(answer.toLowerCase(), anyOf(contains('8'), contains('eight')));

      await model.close();
      await source.close();
      await host.close();
    },
    skip: enabled
        ? false
        : 'Set ADELE_OPENAI_CHATGPT_LIVE_TEST=1 and provide the existing local credential file to enable the experimental source-coding smoke.',
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

Future<_Activation> _startProvider({
  required PluginBackendHost host,
  required CapabilityRegistry registry,
  required String pluginId,
  required File artifact,
  required ProviderDescriptor descriptor,
  List<String> arguments = const <String>[],
  String? configurationContext,
}) async {
  final PluginBackendConnection connection = await host.startPlugin(
    pluginId: pluginId,
    artifactUri: artifact.uri,
    arguments: arguments,
  );
  final ConfigurationContextId context = configurationContext == null
      ? connection.defaultConfigurationContext
      : connection.configurationContext(configurationContext);
  final CapabilityRegistration registration = registry.register(
    provider: descriptor,
    endpoint: AdeleRequestChannelEndpoint(
      channel: connection.channelFor(context, descriptor.serviceId),
      serviceId: descriptor.serviceId,
      isAvailable: () => !connection.isClosed,
    ),
  );
  return _Activation(connection, registration);
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

String _dartExecutable() {
  final String? flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final String executable =
        '$flutterRoot${Platform.pathSeparator}bin${Platform.pathSeparator}cache${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin${Platform.pathSeparator}${Platform.isWindows ? 'dart.exe' : 'dart'}';
    if (File(executable).existsSync()) return executable;
  }
  final String executable = Platform.resolvedExecutable;
  if (File(executable).parent.path.endsWith(
    '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin',
  )) {
    return executable;
  }
  throw StateError('Unable to locate the Dart SDK executable for AOT tests.');
}

String _requiredEnvironment(String name) {
  final String? value = Platform.environment[name];
  if (value == null || value.trim().isEmpty) {
    throw StateError('$name is required for the ChatGPT live test.');
  }
  return value;
}

final class _Activation {
  const _Activation(this.connection, this.registration);

  final PluginBackendConnection connection;
  final CapabilityRegistration registration;

  Future<void> close() async {
    await registration.close();
    if (!connection.isClosed) await connection.close();
  }
}
