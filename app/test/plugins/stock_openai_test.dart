@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/development/agent/development_self_hosting.dart';
import 'package:adele_desktop/plugins/stock_openai.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

void main() {
  test(
    'configuration absence does not enable a provider or read credentials',
    () {
      for (final Map<String, String> environment in <Map<String, String>>[
        <String, String>{},
        <String, String>{'OPENAI_API_KEY': 'unrelated-api-key'},
        <String, String>{'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': ' \t '},
        <String, String>{'ADELE_OPENAI_CHATGPT_ENDPOINT': 'https://[invalid'},
      ]) {
        expect(StockChatGptConfiguration.fromEnvironment(environment), isNull);
      }
      final StockChatGptConfiguration configuration =
          StockChatGptConfiguration.fromEnvironment(const <String, String>{
            'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE':
                '/missing/private/file.json',
            'ADELE_OPENAI_CHATGPT_TEST_MODEL': 'not-the-normal-model',
            'ADELE_OPENAI_CHATGPT_CLIENT_ID': ' ',
          })!;
      expect(configuration.credentialFile, '/missing/private/file.json');
      expect(configuration.model, 'gpt-6-astra');
      expect(configuration.clientId, isNull);
      expect(configuration.instanceId, isNull);
      expect(configuration.issuer, isNull);
      expect(configuration.redirectUri, isNull);
      expect(configuration.endpoint, isNull);
    },
  );

  test('configuration snapshots only the supplied public ChatGPT settings', () {
    final Map<String, String> environment = <String, String>{
      'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': '/private/credential file.json',
      'ADELE_OPENAI_CHATGPT_MODEL': 'explicit-model',
      'ADELE_OPENAI_CHATGPT_CLIENT_ID': 'authorized-client',
      'ADELE_OPENAI_CHATGPT_INSTANCE_ID': 'stock-chatgpt',
      'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER': 'https://auth.example.test',
      'ADELE_OPENAI_CHATGPT_REDIRECT_URI':
          'http://localhost:1455/auth/callback',
      'ADELE_OPENAI_CHATGPT_ENDPOINT':
          'https://responses.example.test/responses',
      'OPENAI_API_KEY': 'not-chatgpt',
      'ADELE_OPENAI_CHATGPT_ACCESS_TOKEN': 'not-public-configuration',
    };
    final StockChatGptConfiguration configuration =
        StockChatGptConfiguration.fromEnvironment(environment)!;
    environment.clear();
    expect(configuration.credentialFile, '/private/credential file.json');
    expect(configuration.model, 'explicit-model');
    expect(configuration.clientId, 'authorized-client');
    expect(configuration.instanceId, 'stock-chatgpt');
    expect(configuration.issuer, Uri.parse('https://auth.example.test'));
    expect(
      configuration.redirectUri,
      Uri.parse('http://localhost:1455/auth/callback'),
    );
    expect(
      configuration.endpoint,
      Uri.parse('https://responses.example.test/responses'),
    );
  });

  test('malformed environment URIs fail without echoing their contents', () {
    for (final String suffix in ['OAUTH_ISSUER', 'REDIRECT_URI', 'ENDPOINT']) {
      expect(
        () => StockChatGptConfiguration.fromEnvironment(<String, String>{
          'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': '/private/credentials.json',
          'ADELE_OPENAI_CHATGPT_$suffix': 'https://[sensitive-config-canary',
        }),
        throwsA(
          isA<FormatException>().having(
            (error) => error.toString(),
            'redacted',
            isNot(contains('sensitive-config-canary')),
          ),
        ),
      );
    }
  });

  test(
    'selfhosting shares identities and masks rather than fabricates an API key',
    () {
      final DevelopmentSelfHostingProviderConfiguration configuration =
          DevelopmentSelfHostingProviderConfiguration.fromEnvironment(
            DevelopmentSelfHostingProfile.chatgpt,
            environment: const <String, String>{
              'OPENAI_API_KEY': 'inherited-api-key',
              'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE':
                  '/private/credentials.json',
            },
          );
      expect(configuration.providerId, stockChatGptProviderId.value);
      expect(configuration.configuredContext, stockChatGptConfigurationContext);
      expect(configuration.selectedModel, stockChatGptDefaultModel);
      expect(configuration.hostEnvironment['OPENAI_API_KEY'], isEmpty);
      expect(
        configuration
            .hostEnvironment['ADELE_OPENAI_CHATGPT_EXPERIMENTAL_CODEX_CLIENT'],
        '1',
      );
    },
  );

  group('real backend activation', () {
    late Directory artifacts;
    late String runtime;
    late File hostArtifact;
    late File pluginArtifact;

    setUpAll(() async {
      final Directory repository = Directory.current.parent;
      artifacts = await Directory.systemTemp.createTemp('adele-stock-openai-');
      addTearDown(() => artifacts.delete(recursive: true));
      final String dart = _dartExecutable();
      runtime = File.fromUri(
        File(dart).parent.uri.resolve(
          Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
        ),
      ).path;
      hostArtifact = File.fromUri(artifacts.uri.resolve('host.aot'));
      pluginArtifact = File.fromUri(artifacts.uri.resolve('openai.aot'));
      for (final target in [
        (
          entrypoint:
              'packages/plugin_backend_host/bin/adele_backend_host.dart',
          artifact: hostArtifact,
        ),
        (
          entrypoint:
              'plugins/openai/packages/backend/bin/openai_model_provider_backend.dart',
          artifact: pluginArtifact,
        ),
      ]) {
        await compileAotSnapshot(
          dartExecutable: dart,
          workingDirectory: repository,
          entrypoint: target.entrypoint,
          artifact: target.artifact,
          stage: 'stock-openai-test',
        );
      }
    });

    for (final String? clientId in [null, 'authorized-stock-client']) {
      test(
        'registers only ChatGPT with ${clientId == null ? 'explicit experimental opt-in' : 'configured client'}',
        () async {
          final PluginBackendHost host = await PluginBackendHost.start(
            dartaotruntimeExecutable: runtime,
            hostArtifactPath: hostArtifact.path,
            environment: const <String, String>{
              'OPENAI_API_KEY': 'inherited-api-key',
              'ADELE_OPENAI_ENDPOINT': 'invalid-inherited-api-endpoint',
              'ADELE_OPENAI_CHATGPT_CLIENT_ID': 'invalid\nclient',
              'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER': 'invalid-inherited-issuer',
              'ADELE_OPENAI_CHATGPT_REDIRECT_URI': 'invalid-inherited-redirect',
              'ADELE_OPENAI_CHATGPT_ENDPOINT': 'invalid-inherited-endpoint',
            },
          );
          addTearDown(host.close);
          final CapabilityRegistry registry = CapabilityRegistry();
          final File missingCredential = File(
            '${artifacts.path}/missing-credential.json',
          );
          final PluginCapabilityActivation activation =
              await activateStockChatGpt(
                host: host,
                registry: registry,
                artifactUri: pluginArtifact.uri,
                configuration: StockChatGptConfiguration(
                  credentialFile: missingCredential.path,
                  clientId: clientId,
                  instanceId: 'test-instance',
                  endpoint: Uri.parse('http://127.0.0.1:1/responses'),
                ),
              );
          addTearDown(activation.close);
          final ProviderDescriptor provider = registry
              .providersFor(modelProviderCapability)
              .single;
          expect(provider.id, stockChatGptProviderId);
          expect(provider.pluginId, stockOpenAiPluginId);
          expect(provider.serviceId, modelProviderServiceId);
          expect(provider.displayName, 'Experimental ChatGPT');
          expect(missingCredential.existsSync(), isFalse);

          await expectLater(
            ModelProviderServiceClient(
              activation.connection.channelFor(
                activation.connection.defaultConfigurationContext,
                modelProviderServiceId,
              ),
            ).invoke(_request()).toList(),
            throwsA(
              isA<PluginRemoteFailure>().having(
                (error) => error.code,
                'code',
                'configuration_context_unavailable',
              ),
            ),
          );
          final ProviderBinding binding = registry.resolve(
            modelProviderCapability,
          );
          final List<ModelProviderEvent> events =
              await ModelProviderServiceClient(
                binding.streamChannel,
              ).invoke(_request()).toList();
          expect(
            events.single.terminal?.failure?.providerCode,
            'missing_credentials',
          );
          expect(
            events.single.terminal?.failure?.kind,
            ModelProviderFailureKind.authentication,
          );
          await activation.close();
          expect(activation.connection.isClosed, isTrue);
          expect(registry.providersFor(modelProviderCapability), isEmpty);
          expect(
            () => binding.streamChannel,
            throwsA(isA<ProviderUnavailable>()),
          );
          expect(host.isClosed, isFalse);
        },
      );
    }
  });
}

ModelProviderRequest _request() => ModelProviderRequest(
  model: stockChatGptDefaultModel,
  instructions: 'Do not make a network request without credentials.',
  input: const <ModelProviderInput>[],
  tools: const <ModelProviderTool>[],
  toolChoice: ModelProviderToolChoice.none,
  maxOutputTokens: null,
  providerOptions: const <String, Object?>{},
  nativeState: null,
);

String _dartExecutable() {
  final String? flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final File executable = File.fromUri(
      Directory(flutterRoot).uri.resolve(
        'bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
      ),
    );
    if (executable.existsSync()) return executable.path;
  }
  final File executable = File(Platform.resolvedExecutable);
  if (executable.parent.path.endsWith(
    '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin',
  )) {
    return executable.path;
  }
  throw StateError('Unable to locate the Dart SDK executable for AOT tests.');
}
