import 'dart:async';
import 'dart:convert';
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
  final bool startupArgumentsOnly =
      bootstrapMessage['startupArgumentsOnly'] == true;
  final Map<String, String> environment = _configurationEnvironment(
    arguments,
    startupArgumentsOnly: startupArgumentsOnly,
  );
  String? configured(String name) {
    final String? value = environment[name];
    return value == null || value.trim().isEmpty ? null : value;
  }

  Uri? configuredUri(String name) {
    final String? value = configured(name);
    if (value == null) return null;
    final Uri uri = Uri.parse(value);
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasFragment) {
      throw const FormatException('Invalid backend configuration URI.');
    }
    return uri;
  }

  final String? apiKey = configured('OPENAI_API_KEY');
  final String? credentialFile = configured(
    'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE',
  );
  final bool chatGptConfigured =
      arguments.length == 2 ||
      configured('ADELE_OPENAI_CHATGPT_CLIENT_ID') != null ||
      environment[openAiExperimentalCodexClientEnvironment] == '1';
  if (!startupArgumentsOnly &&
      arguments.isEmpty &&
      apiKey == null &&
      !chatGptConfigured) {
    throw StateError(
      'The OpenAI backend requires a nonblank OPENAI_API_KEY or an experimental '
      'ChatGPT credential file with an OAuth client ID or explicit Codex client '
      'opt-in.',
    );
  }
  OpenAiOAuthClient? oauth;
  OpenAiModelProvider? apiKeyProvider;
  OpenAiModelProvider? chatGptProvider;
  try {
    if (apiKey != null) {
      apiKeyProvider = OpenAiModelProvider(
        apiKey: apiKey,
        endpoint: configuredUri('ADELE_OPENAI_ENDPOINT'),
      );
    }
    if (chatGptConfigured) {
      if (credentialFile == null || credentialFile.contains('\u0000')) {
        throw const FormatException('A credential file path is required.');
      }
      final OpenAiOAuthClientIdentity identity = openAiOAuthClientIdentity(
        environment,
        allowDevelopmentFallback: false,
      );
      if (identity.experimentalCodexClient) {
        stderr.writeln(
          'EXPERIMENTAL OPT-IN: using the source-visible Codex OAuth public '
          'client. This identity is not an ADELE registration or documented '
          'OpenAI third-party contract.',
        );
      }
      oauth = OpenAiOAuthClient(
        configuration: OpenAiOAuthConfiguration(
          clientId: identity.clientId,
          issuer: configuredUri('ADELE_OPENAI_CHATGPT_OAUTH_ISSUER'),
          redirectUri:
              configuredUri('ADELE_OPENAI_CHATGPT_REDIRECT_URI') ??
              Uri.parse('http://localhost:1455/auth/callback'),
          authorizationParameters: openAiChatGptAuthorizationParameters,
        ),
      );
      final OpenAiChatGptAuth auth = OpenAiChatGptAuth(
        instanceId: openAiChatGptInstanceId(environment),
        store: FileOpenAiCredentialStore(File(credentialFile)),
        oauth: oauth,
      );
      chatGptProvider = OpenAiModelProvider.chatGpt(
        auth: auth,
        endpoint: configuredUri('ADELE_OPENAI_CHATGPT_ENDPOINT'),
      );
    }
  } on Object {
    apiKeyProvider?.close();
    chatGptProvider?.close();
    oauth?.close();
    // URI/argument exceptions may contain configuration values or credentials.
    throw StateError(
      'Invalid OpenAI backend configuration. Check the API key, ChatGPT '
      'credential-file path, OAuth client ID or explicit Codex client opt-in, '
      'and public OAuth/endpoint settings.',
    );
  }
  final ReceivePort requests = ReceivePort();
  try {
    final AdeleConfigurationContextRouter router =
        AdeleConfigurationContextRouter(
          contexts: <String, Map<String, AdeleBackendDispatcher>>{
            if (apiKeyProvider != null)
              defaultConfigurationContext: <String, AdeleBackendDispatcher>{
                modelProviderServiceId: ModelProviderServiceDispatcher(
                  apiKeyProvider,
                ),
              },
            if (chatGptProvider != null)
              openAiChatGptConfigurationContext:
                  <String, AdeleBackendDispatcher>{
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
      'capabilityExposures': [
        if (apiKeyProvider != null)
          AdeleCapabilityExposure(
            providerId: openAiApiKeyProviderId,
            capabilityId: modelProviderCapability.id.value,
            capabilityMajorVersion: modelProviderCapability.majorVersion,
            serviceId: modelProviderServiceId,
            displayName: 'OpenAI API Key',
            configurationContext: defaultConfigurationContext,
          ).toMap(),
        if (chatGptProvider != null)
          AdeleCapabilityExposure(
            providerId: openAiChatGptProviderId,
            capabilityId: modelProviderCapability.id.value,
            capabilityMajorVersion: modelProviderCapability.majorVersion,
            serviceId: modelProviderServiceId,
            displayName: 'Experimental ChatGPT',
            configurationContext: openAiChatGptConfigurationContext,
          ).toMap(),
      ],
    });
    await for (final Object? request in requests) {
      if (request is! Map) continue;
      if (request['method'] == 'shutdown' && request['requestId'] is int) {
        await router.close();
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
  } finally {
    requests.close();
    apiKeyProvider?.close();
    chatGptProvider?.close();
    oauth?.close();
  }
}

Map<String, String> _configurationEnvironment(
  List<String> arguments, {
  required bool startupArgumentsOnly,
}) {
  if (arguments.isEmpty) {
    return startupArgumentsOnly
        ? const <String, String>{}
        : Platform.environment;
  }
  try {
    // Plugin-local startup contract: a file path and public configuration only.
    // Supplying any arguments disables environment fallback, including API keys.
    if (arguments.length == 1 && arguments.single == '--chatgpt-only') {
      return const <String, String>{};
    }
    if (arguments.length != 2 || arguments.first != '--chatgpt-only') {
      throw const FormatException();
    }
    final Object? decoded = jsonDecode(arguments[1]);
    if (decoded is! Map<String, Object?>) throw const FormatException();
    const Map<String, String> fields = <String, String>{
      'credentialFile': 'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE',
      'clientId': 'ADELE_OPENAI_CHATGPT_CLIENT_ID',
      'instanceId': 'ADELE_OPENAI_CHATGPT_INSTANCE_ID',
      'issuer': 'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER',
      'redirectUri': 'ADELE_OPENAI_CHATGPT_REDIRECT_URI',
      'endpoint': 'ADELE_OPENAI_CHATGPT_ENDPOINT',
    };
    final Map<String, String> environment = <String, String>{};
    for (final MapEntry<String, Object?> entry in decoded.entries) {
      if (entry.key == 'experimentalCodexClient') {
        if (entry.value is! bool) throw const FormatException();
        environment[openAiExperimentalCodexClientEnvironment] =
            entry.value == true ? '1' : '0';
        continue;
      }
      final String? name = fields[entry.key];
      final Object? value = entry.value;
      if (name == null ||
          value is! String ||
          value.trim().isEmpty ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
        throw const FormatException();
      }
      environment[name] = value;
    }
    if (!environment.containsKey('ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE')) {
      throw const FormatException();
    }
    return environment;
  } on Object {
    throw StateError(
      'Invalid OpenAI backend startup arguments. Expected --chatgpt-only and '
      'a JSON object containing a credential-file path and public ChatGPT '
      'configuration only; inline credentials are not accepted.',
    );
  }
}
