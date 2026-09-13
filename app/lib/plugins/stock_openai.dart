import 'dart:convert';
import 'dart:io' show Platform;

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

// Transitional stock bootstrap metadata, intentionally mirroring the OpenAI
// backend contract while application composition is hard-coded. Future plugin
// discovery/profile activation should supply plugin-owned identities and exposure
// metadata, replacing this boundary rather than adding a permanent constants API.
// Generic application/runtime infrastructure must remain OpenAI-unaware. The
// real-AOT normal ChatGPT integration validates this temporary pairing.
const String stockOpenAiPluginId = 'dev.adele.openai';
const String stockChatGptConfigurationContext = 'chatgpt-experimental';
const String stockChatGptDefaultModel = 'gpt-6-astra';
const String stockChatGptProviderIdValue =
    'dev.adele.openai.chatgpt-experimental';
final ProviderId stockChatGptProviderId = ProviderId(
  stockChatGptProviderIdValue,
);

final class StockChatGptConfiguration {
  const StockChatGptConfiguration({
    required this.credentialFile,
    this.model = stockChatGptDefaultModel,
    this.clientId,
    this.instanceId,
    this.issuer,
    this.redirectUri,
    this.endpoint,
  });

  final String credentialFile;
  final String model;
  final String? clientId;
  final String? instanceId;
  final Uri? issuer;
  final Uri? redirectUri;
  final Uri? endpoint;

  static StockChatGptConfiguration? fromEnvironment([
    Map<String, String>? environment,
  ]) {
    final Map<String, String> source = environment ?? Platform.environment;
    String? configured(String suffix) {
      final String? value = source['ADELE_OPENAI_CHATGPT_$suffix'];
      return value == null || value.trim().isEmpty ? null : value;
    }

    final String? credentialFile = configured('CREDENTIAL_FILE');
    if (credentialFile == null) return null;
    Uri? configuredUri(String suffix) {
      final String? value = configured(suffix);
      if (value == null) return null;
      try {
        return Uri.parse(value);
      } on FormatException {
        throw const FormatException('Invalid stock ChatGPT configuration URI.');
      }
    }

    return StockChatGptConfiguration(
      credentialFile: credentialFile,
      model: configured('MODEL') ?? stockChatGptDefaultModel,
      clientId: configured('CLIENT_ID'),
      instanceId: configured('INSTANCE_ID'),
      issuer: configuredUri('OAUTH_ISSUER'),
      redirectUri: configuredUri('REDIRECT_URI'),
      endpoint: configuredUri('ENDPOINT'),
    );
  }
}

PluginCapabilityExposure stockChatGptExposure(
  PluginBackendConnection connection,
) => PluginCapabilityExposure(
  provider: ProviderDescriptor(
    id: stockChatGptProviderId,
    capability: modelProviderCapability,
    pluginId: stockOpenAiPluginId,
    displayName: 'Experimental ChatGPT',
    serviceId: modelProviderServiceId,
  ),
  configurationContext: connection.configurationContext(
    stockChatGptConfigurationContext,
  ),
);

Future<PluginCapabilityActivation> activateStockChatGpt({
  required PluginBackendHost host,
  required CapabilityRegistry registry,
  required Uri artifactUri,
  required StockChatGptConfiguration configuration,
}) async {
  final PluginBackendConnection connection = await host.startPlugin(
    pluginId: stockOpenAiPluginId,
    artifactUri: artifactUri,
    arguments: <String>[
      '--chatgpt-only',
      jsonEncode(<String, Object?>{
        'credentialFile': configuration.credentialFile,
        if (configuration.clientId != null)
          'clientId': configuration.clientId
        else
          // Match selfhosting's explicit experimental public-client opt-in.
          'experimentalCodexClient': true,
        if (configuration.instanceId != null)
          'instanceId': configuration.instanceId,
        if (configuration.issuer != null)
          'issuer': configuration.issuer.toString(),
        if (configuration.redirectUri != null)
          'redirectUri': configuration.redirectUri.toString(),
        if (configuration.endpoint != null)
          'endpoint': configuration.endpoint.toString(),
      }),
    ],
  );
  try {
    return await PluginCapabilityActivation.register(
      connection: connection,
      registry: registry,
      exposures: <PluginCapabilityExposure>[stockChatGptExposure(connection)],
    );
  } on Object {
    try {
      await connection.close();
    } on Object {
      // Preserve registration failure; the owning bootstrap also closes its host.
    }
    rethrow;
  }
}
