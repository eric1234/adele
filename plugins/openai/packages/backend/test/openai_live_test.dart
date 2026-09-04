import 'dart:io';

import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:openai_model_provider_backend/openai_model_provider_backend.dart';
import 'package:test/test.dart';

void main() {
  final bool enabled = Platform.environment['ADELE_OPENAI_LIVE_TEST'] == '1';
  test(
    'streams one real OpenAI Responses completion',
    () async {
      final String apiKey = Platform.environment['OPENAI_API_KEY']!;
      final String model = Platform.environment['ADELE_OPENAI_TEST_MODEL']!;
      expect(apiKey, isNotEmpty);
      expect(model, isNotEmpty);
      final OpenAiModelProvider provider = OpenAiModelProvider(apiKey: apiKey);
      addTearDown(provider.close);
      final List<ModelProviderEvent> events = await provider
          .invoke(
            ModelProviderRequest(
              model: model,
              instructions: 'Answer concisely.',
              input: <ModelProviderInput>[
                ModelProviderInput(
                  kind: ModelProviderInputKind.message,
                  message: ModelProviderMessage(
                    role: ModelProviderMessageRole.user,
                    content: <ModelProviderContent>[
                      ModelProviderContent(
                        kind: ModelProviderContentKind.text,
                        text: 'Reply with exactly: ADELE OpenAI live smoke.',
                      ),
                    ],
                  ),
                  toolProposal: null,
                  toolOutcome: null,
                  itemId: null,
                  nativeMetadata: null,
                ),
              ],
              tools: const <ModelProviderTool>[],
              toolChoice: ModelProviderToolChoice.none,
              maxOutputTokens: 64,
              providerOptions: const <String, Object?>{},
              nativeState: null,
            ),
          )
          .toList();
      final ModelProviderTerminal? terminal = events.last.terminal;
      expect(
        terminal?.settlement,
        ModelProviderSettlement.completed,
        reason:
            '${terminal?.failure?.kind.name}: '
            '${terminal?.failure?.providerCode}: '
            '${terminal?.failure?.providerMessage}: '
            '${terminal?.failure?.providerDetails}',
      );
      expect(events.where((event) => event.output?.text != null), isNotEmpty);
    },
    skip: enabled
        ? false
        : 'Set ADELE_OPENAI_LIVE_TEST=1 to enable paid network validation.',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
