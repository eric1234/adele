import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/development/agent/agent_capability_adapters.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'source_coding_live_test_support.dart';

const String _openAiPluginId = 'dev.adele.openai';
const String _chatGptProviderId = 'dev.adele.openai.chatgpt-experimental';

void main() {
  final bool enabled =
      Platform.environment['ADELE_OPENAI_CHATGPT_LIVE_TEST'] == '1';
  late SourceCodingLiveArtifacts artifacts;

  setUpAll(() async {
    if (!enabled) return;
    artifacts = await SourceCodingLiveArtifacts.compile(
      'phase-v-a5-chatgpt-source-live',
    );
  });

  test(
    'experimental ChatGPT searches and reads the real ADELE strategy source',
    () async {
      final Map<String, String> environment = <String, String>{
        'OPENAI_API_KEY': 'unused-live-source-coding-key',
        'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': _requiredEnvironment(
          'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE',
        ),
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
      final SourceCodingLiveHarness harness =
          await SourceCodingLiveHarness.start(
            artifacts: artifacts,
            hostEnvironment: environment,
            identity: 'chatgpt',
            taskTitle: 'Inspect ADELE source with ChatGPT',
          );
      addTearDown(harness.close);
      final _Activation model = await _startChatGptProvider(
        host: harness.host,
        registry: harness.registry,
        artifact: artifacts.openAiArtifact,
      );
      addTearDown(model.close);
      final ModelProviderCapabilityAdapter modelAdapter =
          ModelProviderCapabilityAdapter(
            harness.registry.resolve(
              modelProviderCapability,
              providerId: ProviderId(_chatGptProviderId),
            ),
            selectedModel:
                Platform.environment['ADELE_OPENAI_CHATGPT_TEST_MODEL'] ??
                'gpt-5.5',
          );

      final SourceCodingLiveResult result = await harness.run(
        identity: 'chatgpt',
        model: modelAdapter,
      );

      expectSuccessfulSourceCodingRun(
        result: result,
        authority: harness.authority,
      );
      await model.close();
      await harness.close();
    },
    skip: enabled
        ? false
        : 'Set ADELE_OPENAI_CHATGPT_LIVE_TEST=1 and provide the existing '
              'local credential file to enable the experimental full-stack '
              'source-coding smoke.',
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

Future<_Activation> _startChatGptProvider({
  required PluginBackendHost host,
  required CapabilityRegistry registry,
  required File artifact,
}) async {
  final ProviderDescriptor descriptor = ProviderDescriptor(
    id: ProviderId(_chatGptProviderId),
    capability: modelProviderCapability,
    pluginId: _openAiPluginId,
    displayName: 'Experimental ChatGPT',
    serviceId: modelProviderServiceId,
  );
  final PluginBackendConnection connection = await host.startPlugin(
    pluginId: _openAiPluginId,
    artifactUri: artifact.uri,
  );
  final CapabilityRegistration registration = registry.register(
    provider: descriptor,
    endpoint: AdeleRequestChannelEndpoint(
      channel: connection.channelFor(
        connection.configurationContext('chatgpt-experimental'),
        descriptor.serviceId,
      ),
      serviceId: descriptor.serviceId,
      isAvailable: () => !connection.isClosed,
    ),
  );
  return _Activation(connection, registration);
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
