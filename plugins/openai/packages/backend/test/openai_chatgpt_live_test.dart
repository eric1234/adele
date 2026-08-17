import 'dart:io';

import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:openai_model_provider_backend/openai_model_provider_backend.dart';
import 'package:openai_model_provider_backend/src/openai_chatgpt_auth.dart';
import 'package:test/test.dart';

void main() {
  final bool enabled =
      Platform.environment['ADELE_OPENAI_CHATGPT_LIVE_TEST'] == '1';
  test(
    'streams one real ChatGPT subscription Responses completion',
    () async {
      final String credentialPath = _requiredEnvironment(
        'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE',
      );
      final OpenAiOAuthClient oauth = OpenAiOAuthClient(
        configuration: OpenAiOAuthConfiguration(
          clientId:
              Platform.environment['ADELE_OPENAI_CHATGPT_CLIENT_ID'] ??
              openAiExperimentalCodexOAuthClientId,
          issuer: Uri.parse(
            Platform.environment['ADELE_OPENAI_CHATGPT_OAUTH_ISSUER'] ??
                'https://auth.openai.com',
          ),
          redirectUri: Uri.parse(
            Platform.environment['ADELE_OPENAI_CHATGPT_REDIRECT_URI'] ??
                'http://localhost:1455/auth/callback',
          ),
        ),
      );
      addTearDown(oauth.close);
      final OpenAiChatGptAuth auth = OpenAiChatGptAuth(
        instanceId:
            Platform.environment['ADELE_OPENAI_CHATGPT_INSTANCE_ID'] ??
            'development-chatgpt',
        store: FileOpenAiCredentialStore(File(credentialPath)),
        oauth: oauth,
      );
      final String? endpointValue =
          Platform.environment['ADELE_OPENAI_CHATGPT_ENDPOINT'];
      final OpenAiModelProvider provider = OpenAiModelProvider.chatGpt(
        auth: auth,
        endpoint: endpointValue == null ? null : Uri.parse(endpointValue),
      );
      addTearDown(provider.close);

      final List<ModelProviderEvent> events = await provider
          .invoke(
            ModelProviderRequest(
              model:
                  Platform.environment['ADELE_OPENAI_CHATGPT_TEST_MODEL'] ??
                  'gpt-5.4',
              instructions: 'Reply with exactly the single word OK.',
              input: <ModelProviderInput>[
                ModelProviderInput(
                  kind: ModelProviderInputKind.message,
                  message: ModelProviderMessage(
                    role: ModelProviderMessageRole.user,
                    content: <ModelProviderContent>[
                      ModelProviderContent(
                        kind: ModelProviderContentKind.text,
                        text:
                            'Validate the ADELE ChatGPT provider integration.',
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
              maxOutputTokens: null,
              providerOptions: const <String, Object?>{},
              nativeState: null,
            ),
          )
          .toList();

      expect(
        events.last.terminal?.settlement,
        ModelProviderSettlement.completed,
      );
      expect(
        events
            .map((ModelProviderEvent event) => event.output?.text)
            .whereType<String>()
            .join(),
        'OK',
      );
    },
    skip: enabled
        ? false
        : 'Set ADELE_OPENAI_CHATGPT_LIVE_TEST=1 and provide the local credential file to enable experimental network validation.',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

String _requiredEnvironment(String name) {
  final String? value = Platform.environment[name];
  if (value == null || value.trim().isEmpty) {
    throw StateError('$name is required for the ChatGPT live test.');
  }
  return value;
}
