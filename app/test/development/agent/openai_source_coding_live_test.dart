import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/development/agent/agent_capability_adapters.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'source_coding_live_test_support.dart';

void main() {
  final bool enabled =
      Platform.environment['ADELE_OPENAI_SOURCE_CODING_LIVE_TEST'] == '1';
  late SourceCodingLiveArtifacts artifacts;

  setUpAll(() async {
    if (!enabled) return;
    artifacts = await SourceCodingLiveArtifacts.compile(
      'phase-v-a5-openai-source-live',
    );
  });

  test(
    'OpenAI API key searches and reads the real ADELE strategy source',
    () async {
      final SourceCodingLiveHarness harness =
          await SourceCodingLiveHarness.start(
            artifacts: artifacts,
            hostEnvironment: <String, String>{
              'OPENAI_API_KEY': _requiredEnvironment('OPENAI_API_KEY'),
              'ADELE_OPENAI_ENDPOINT': 'https://api.openai.com/v1/responses',
            },
            identity: 'openai-api-key',
            taskTitle: 'Inspect ADELE source with OpenAI API key',
          );
      addTearDown(harness.close);
      final SourceCodingLiveProviderActivation model =
          await startOpenAiApiKeyProvider(
            host: harness.host,
            registry: harness.registry,
            artifact: artifacts.openAiArtifact,
          );
      addTearDown(model.close);
      final ModelProviderCapabilityAdapter modelAdapter =
          ModelProviderCapabilityAdapter(
            harness.registry.resolve(
              modelProviderCapability,
              providerId: ProviderId(openAiApiKeyProviderId),
            ),
            selectedModel: _requiredEnvironment('ADELE_OPENAI_TEST_MODEL'),
          );

      final SourceCodingLiveResult result = await harness.run(
        identity: 'openai-api-key',
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
        : 'Set ADELE_OPENAI_SOURCE_CODING_LIVE_TEST=1 and provide '
              'OPENAI_API_KEY plus ADELE_OPENAI_TEST_MODEL to enable the '
              'paid full-stack source-coding smoke.',
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

String _requiredEnvironment(String name) {
  final String? value = Platform.environment[name];
  if (value == null || value.trim().isEmpty) {
    throw StateError('$name is required for the OpenAI API-key live test.');
  }
  return value;
}
