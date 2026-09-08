import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/development/agent/agent_capability_adapters.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'source_coding_live_test_support.dart';

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
      final String selectedModel = sourceCodingChatGptSelectedModel();
      final SourceCodingLiveHarness harness =
          await SourceCodingLiveHarness.start(
            artifacts: artifacts,
            hostEnvironment: sourceCodingChatGptHostEnvironment(),
            identity: 'chatgpt',
            taskTitle: 'Inspect ADELE source with ChatGPT',
          );
      addTearDown(harness.close);
      final SourceCodingLiveProviderActivation model =
          await startOpenAiChatGptProvider(
            host: harness.host,
            registry: harness.registry,
            artifact: artifacts.openAiArtifact,
          );
      addTearDown(model.close);
      final ModelProviderCapabilityAdapter modelAdapter =
          ModelProviderCapabilityAdapter(
            harness.registry.resolve(
              modelProviderCapability,
              providerId: ProviderId(openAiChatGptProviderId),
            ),
            selectedModel: selectedModel,
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
