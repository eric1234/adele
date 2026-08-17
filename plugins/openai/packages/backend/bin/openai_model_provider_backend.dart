import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:openai_model_provider_backend/openai_model_provider_backend.dart';
import 'package:openai_model_provider_backend/src/openai_chatgpt_auth.dart';

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  if (bootstrapMessage is! Map) {
    throw StateError('Missing ADELE backend-host bootstrap metadata.');
  }
  final Object? bootstrapPort = bootstrapMessage['bootstrapPort'];
  final Object? responsePort = bootstrapMessage['responsePort'];
  if (bootstrapPort is! SendPort || responsePort is! SendPort) {
    throw ArgumentError.value(bootstrapMessage, 'bootstrapMessage');
  }
  final Object? defaultConfigurationContext =
      bootstrapMessage['defaultConfigurationContext'];
  if (defaultConfigurationContext is! String) {
    throw ArgumentError.value(bootstrapMessage, 'bootstrapMessage');
  }
  final String? apiKey = Platform.environment['OPENAI_API_KEY'];
  if (apiKey == null || apiKey.trim().isEmpty) {
    throw StateError('OPENAI_API_KEY is required by the OpenAI backend.');
  }
  final String? endpointValue = Platform.environment['ADELE_OPENAI_ENDPOINT'];
  final OpenAiModelProvider apiKeyProvider = OpenAiModelProvider(
    apiKey: apiKey,
    endpoint: endpointValue == null ? null : Uri.parse(endpointValue),
  );
  final String? credentialFile =
      Platform.environment['ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE'];
  final String? oauthClientId =
      Platform.environment['ADELE_OPENAI_CHATGPT_CLIENT_ID'];
  final String? chatGptEndpointValue =
      Platform.environment['ADELE_OPENAI_CHATGPT_ENDPOINT'];
  final String? oauthIssuerValue =
      Platform.environment['ADELE_OPENAI_CHATGPT_OAUTH_ISSUER'];
  final String? redirectValue =
      Platform.environment['ADELE_OPENAI_CHATGPT_REDIRECT_URI'];
  OpenAiOAuthClient? oauth;
  OpenAiModelProvider? chatGptProvider;
  if (credentialFile != null || oauthClientId != null) {
    if (credentialFile == null || credentialFile.isEmpty) {
      throw StateError(
        'The experimental ChatGPT configuration requires a credential file.',
      );
    }
    final String effectiveClientId =
        oauthClientId ?? openAiExperimentalCodexOAuthClientId;
    if (oauthClientId == null) {
      stderr.writeln(
        'EXPERIMENTAL: using the source-visible Codex OAuth public client. '
        'This path is not a documented OpenAI third-party contract.',
      );
    }
    oauth = OpenAiOAuthClient(
      configuration: OpenAiOAuthConfiguration(
        clientId: effectiveClientId,
        issuer: oauthIssuerValue == null ? null : Uri.parse(oauthIssuerValue),
        redirectUri: Uri.parse(
          redirectValue ?? 'http://localhost:1455/auth/callback',
        ),
        authorizationParameters: const <String, String>{
          'id_token_add_organizations': 'true',
          'codex_cli_simplified_flow': 'true',
          'originator': 'adele',
        },
      ),
    );
    final OpenAiChatGptAuth auth = OpenAiChatGptAuth(
      instanceId:
          Platform.environment['ADELE_OPENAI_CHATGPT_INSTANCE_ID'] ??
          'development-chatgpt',
      store: FileOpenAiCredentialStore(File(credentialFile)),
      oauth: oauth,
    );
    chatGptProvider = OpenAiModelProvider.chatGpt(
      auth: auth,
      endpoint: chatGptEndpointValue == null
          ? null
          : Uri.parse(chatGptEndpointValue),
    );
  }
  final ReceivePort requests = ReceivePort();
  final AdeleConfigurationContextRouter router =
      AdeleConfigurationContextRouter(
        contexts: <String, Map<String, AdeleBackendDispatcher>>{
          defaultConfigurationContext: <String, AdeleBackendDispatcher>{
            modelProviderServiceId: ModelProviderServiceDispatcher(
              apiKeyProvider,
            ),
          },
          if (chatGptProvider != null)
            openAiChatGptConfigurationContext: <String, AdeleBackendDispatcher>{
              modelProviderServiceId: ModelProviderServiceDispatcher(
                chatGptProvider,
              ),
            },
        },
      );
  bootstrapPort.send(<String, Object?>{
    'kind': 'ready',
    'commandPort': requests.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
  });
  await for (final Object? request in requests) {
    if (request is! Map) continue;
    if (request['method'] == 'shutdown' && request['requestId'] is int) {
      await router.close();
      apiKeyProvider.close();
      chatGptProvider?.close();
      oauth?.close();
      responsePort.send(<String, Object?>{
        'kind': 'response',
        'requestId': request['requestId'],
        'ok': true,
        'payload': <String, Object?>{'stopping': true},
      });
      requests.close();
      continue;
    }
    unawaited(router.handle(request, responsePort.send));
  }
}
