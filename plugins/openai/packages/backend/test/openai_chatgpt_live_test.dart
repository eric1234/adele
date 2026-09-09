import 'dart:io';

import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:openai_model_provider_backend/openai_model_provider_backend.dart';
import 'package:openai_model_provider_backend/src/openai_chatgpt_auth.dart';
import 'package:test/test.dart';

void main() {
  final bool enabled =
      Platform.environment['ADELE_OPENAI_CHATGPT_LIVE_TEST'] == '1';
  test(
    'continues ordinary function tools through real ChatGPT Responses',
    () async {
      final String credentialPath = _requiredEnvironment(
        'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE',
      );
      final OpenAiOAuthClientIdentity identity = openAiOAuthClientIdentity(
        Platform.environment,
        allowDevelopmentFallback: true,
      );
      final OpenAiOAuthClient oauth = OpenAiOAuthClient(
        configuration: OpenAiOAuthConfiguration(
          clientId: identity.clientId,
          issuer: Uri.parse(
            Platform.environment['ADELE_OPENAI_CHATGPT_OAUTH_ISSUER'] ??
                'https://auth.openai.com',
          ),
          redirectUri: Uri.parse(
            Platform.environment['ADELE_OPENAI_CHATGPT_REDIRECT_URI'] ??
                'http://localhost:1455/auth/callback',
          ),
          authorizationParameters: openAiChatGptAuthorizationParameters,
        ),
      );
      addTearDown(oauth.close);
      final OpenAiChatGptAuth auth = OpenAiChatGptAuth(
        instanceId: openAiChatGptInstanceId(Platform.environment),
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

      final String selectedModel =
          Platform.environment['ADELE_OPENAI_CHATGPT_TEST_MODEL'] ?? 'gpt-5.5';
      expect(selectedModel.trim(), isNotEmpty);
      const String toolResult = 'ADELE_TOOL_CONTINUATION_OK';
      final List<ModelProviderInput> input = <ModelProviderInput>[
        ModelProviderInput(
          kind: ModelProviderInputKind.message,
          message: ModelProviderMessage(
            role: ModelProviderMessageRole.user,
            content: <ModelProviderContent>[
              ModelProviderContent(
                kind: ModelProviderContentKind.text,
                text: 'Validate the ADELE ChatGPT provider tool continuation.',
              ),
            ],
          ),
          toolProposal: null,
          toolOutcome: null,
          itemId: null,
          nativeMetadata: null,
        ),
      ];
      print('ChatGPT backend selected model: $selectedModel');
      for (var invocation = 0; invocation < 2; invocation++) {
        final List<ModelProviderEvent> events = await provider
            .invoke(
              ModelProviderRequest(
                model: selectedModel,
                instructions:
                    'First call adele_validation_echo with value "adele-validation". '
                    'Do not answer before receiving its result. Once tool results '
                    'are available, reply with exactly the tool result text, '
                    'without formatting or further tool calls.',
                input: input,
                tools: <ModelProviderTool>[
                  ModelProviderTool(
                    name: 'adele_validation_echo',
                    description: 'Return a deterministic validation receipt.',
                    argumentsSchema: const <String, Object?>{
                      'type': 'object',
                      'properties': <String, Object?>{
                        'value': <String, Object?>{
                          'type': 'string',
                          'enum': <String>['adele-validation'],
                        },
                      },
                      'required': <String>['value'],
                      'additionalProperties': false,
                    },
                  ),
                ],
                toolChoice: invocation == 0
                    ? ModelProviderToolChoice.auto
                    : ModelProviderToolChoice.none,
                maxOutputTokens: null,
                providerOptions: const <String, Object?>{},
                nativeState: null,
              ),
            )
            .toList();
        final ModelProviderTerminal terminal = events
            .map((event) => event.terminal)
            .whereType<ModelProviderTerminal>()
            .single;
        print(
          'ChatGPT backend invocation ${invocation + 1}: '
          '${terminal.settlement.name}, effective model: ${terminal.effectiveModel}',
        );
        expect(
          terminal.settlement,
          ModelProviderSettlement.completed,
          reason:
              '${terminal.failure?.kind.name}: '
              '${terminal.failure?.providerCode}: '
              '${terminal.failure?.providerMessage}: '
              '${terminal.failure?.providerDetails}',
        );
        expect(terminal.effectiveModel, isNotNull);
        expect(terminal.effectiveModel, selectedModel);
        final List<ModelProviderOutput> outputs = events
            .map((event) => event.output)
            .whereType<ModelProviderOutput>()
            .toList();
        final List<ModelProviderToolProposal> proposals = outputs
            .map((output) => output.toolProposal)
            .whereType<ModelProviderToolProposal>()
            .toList();
        print(
          'ChatGPT backend invocation ${invocation + 1} proposals: '
          '${proposals.length} ${proposals.map((proposal) => proposal.name).toList()}',
        );
        if (invocation == 0) {
          expect(proposals, isNotEmpty);
          expect(
            proposals.map((proposal) => proposal.callId).toSet(),
            hasLength(proposals.length),
          );
          // Replay every completed item in provider order before any outcomes.
          input.addAll(outputs.map(_replay));
          for (final ModelProviderToolProposal proposal in proposals) {
            expect(proposal.name, 'adele_validation_echo');
            expect(proposal.arguments, <String, Object?>{
              'value': 'adele-validation',
            });
            expect(proposal.callId.trim(), isNotEmpty);
            input.add(
              ModelProviderInput(
                kind: ModelProviderInputKind.toolOutcome,
                message: null,
                toolProposal: null,
                toolOutcome: ModelProviderToolOutcome(
                  callId: proposal.callId,
                  status: ModelProviderToolOutcomeStatus.success,
                  content: toolResult,
                ),
                itemId: null,
                nativeMetadata: null,
              ),
            );
          }
        } else {
          expect(proposals, isEmpty);
          final String answer = outputs
              .map((output) => output.text)
              .whereType<String>()
              .join()
              .trim();
          expect(answer, toolResult);
          print('ChatGPT backend final assistant response: $answer');
        }
      }
    },
    skip: enabled
        ? false
        : 'Set ADELE_OPENAI_CHATGPT_LIVE_TEST=1 and provide the local credential file to enable experimental network validation.',
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

ModelProviderInput _replay(ModelProviderOutput output) => ModelProviderInput(
  kind: switch (output.kind) {
    ModelProviderOutputKind.nativeItem => ModelProviderInputKind.nativeItem,
    ModelProviderOutputKind.text => ModelProviderInputKind.message,
    ModelProviderOutputKind.toolProposal => ModelProviderInputKind.toolProposal,
  },
  message: output.kind == ModelProviderOutputKind.text
      ? ModelProviderMessage(
          role: ModelProviderMessageRole.assistant,
          content: <ModelProviderContent>[
            ModelProviderContent(
              kind: ModelProviderContentKind.text,
              text: output.text!,
            ),
          ],
        )
      : null,
  toolProposal: output.toolProposal,
  toolOutcome: null,
  itemId: output.itemId,
  nativeMetadata: output.nativeMetadata,
);

String _requiredEnvironment(String name) {
  final String? value = Platform.environment[name];
  if (value == null || value.trim().isEmpty) {
    throw StateError('$name is required for the ChatGPT live test.');
  }
  return value;
}
