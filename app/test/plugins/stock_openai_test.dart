@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/development/agent/development_self_hosting.dart';
import 'package:adele_desktop/plugins/temporary_chatgpt_selection.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const String _openAiPluginId = 'dev.adele.openai';

void main() {
  test(
    'product selection defaults without interpreting backend configuration',
    () {
      for (final Map<String, String> environment in <Map<String, String>>[
        <String, String>{},
        <String, String>{'OPENAI_API_KEY': 'unrelated-api-key'},
        <String, String>{'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': ' \t '},
        <String, String>{'ADELE_OPENAI_CHATGPT_ENDPOINT': 'https://[invalid'},
        <String, String>{'ADELE_OPENAI_CHATGPT_MODEL': ' \t '},
        <String, String>{'ADELE_OPENAI_CHATGPT_TEST_MODEL': 'selfhosting-only'},
      ]) {
        expect(
          StockChatGptConfiguration.fromEnvironment(environment).model,
          'gpt-6-astra',
        );
      }
    },
  );

  test('product selection snapshots only the requested model', () {
    final Map<String, String> environment = <String, String>{
      'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': '/private/credential file.json',
      'ADELE_OPENAI_CHATGPT_MODEL': 'explicit-model',
      'ADELE_OPENAI_CHATGPT_CLIENT_ID': 'invalid\nclient',
      'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER': 'https://[invalid',
      'ADELE_OPENAI_CHATGPT_REDIRECT_URI': 'https://[invalid',
      'ADELE_OPENAI_CHATGPT_ENDPOINT': 'https://[invalid',
      'OPENAI_API_KEY': 'not-chatgpt',
      'ADELE_OPENAI_CHATGPT_ACCESS_TOKEN': 'not-public-configuration',
    };
    final StockChatGptConfiguration configuration =
        StockChatGptConfiguration.fromEnvironment(environment);
    environment.clear();
    expect(configuration.model, 'explicit-model');
  });

  test(
    'normal and selfhosting selections retain the same ChatGPT identity',
    () {
      expect(
        developmentSelfHostingChatGptProviderId,
        stockChatGptProviderId.value,
      );
      expect(
        developmentSelfHostingChatGptDefaultModel,
        stockChatGptDefaultModel,
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
          final PluginBackendConnection connection = await host.startPlugin(
            pluginId: _openAiPluginId,
            artifactUri: pluginArtifact.uri,
            arguments: [
              '--chatgpt-only',
              jsonEncode({
                'credentialFile': missingCredential.path,
                if (clientId != null)
                  'clientId': clientId
                else
                  'experimentalCodexClient': true,
                'instanceId': 'test-instance',
                'endpoint': 'http://127.0.0.1:1/responses',
              }),
            ],
          );
          addTearDown(connection.close);
          final PluginCapabilityActivation activation =
              await PluginCapabilityActivation.registerAdvertised(
                connection: connection,
                registry: registry,
              );
          addTearDown(activation.close);
          final ProviderDescriptor provider = registry
              .providersFor(modelProviderCapability)
              .single;
          expect(provider.id, stockChatGptProviderId);
          expect(provider.pluginId, _openAiPluginId);
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

    for (final fixture in [
      (
        profile: DevelopmentSelfHostingProfile.chatgpt,
        apiKey: false,
        chatGpt: true,
      ),
      (
        profile: DevelopmentSelfHostingProfile.apiKey,
        apiKey: true,
        chatGpt: false,
      ),
      (
        profile: DevelopmentSelfHostingProfile.chatgpt,
        apiKey: true,
        chatGpt: true,
      ),
      (
        profile: DevelopmentSelfHostingProfile.apiKey,
        apiKey: true,
        chatGpt: true,
      ),
    ]) {
      test('selfhosting ${fixture.profile.cliName} registers online contexts '
          'apiKey=${fixture.apiKey} chatGpt=${fixture.chatGpt}', () async {
        final PluginBackendHost host = await PluginBackendHost.start(
          dartaotruntimeExecutable: runtime,
          hostArtifactPath: hostArtifact.path,
          environment: {
            'OPENAI_API_KEY': fixture.apiKey ? 'fixture-api-key' : '',
            'ADELE_OPENAI_ENDPOINT': 'http://127.0.0.1:1/responses',
            'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE':
                '${artifacts.path}/missing-credential.json',
            'ADELE_OPENAI_CHATGPT_CLIENT_ID': fixture.chatGpt ? 'fixture' : '',
            'ADELE_OPENAI_CHATGPT_EXPERIMENTAL_CODEX_CLIENT': '0',
            'ADELE_OPENAI_CHATGPT_INSTANCE_ID': 'fixture',
            'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER': 'http://127.0.0.1:1',
            'ADELE_OPENAI_CHATGPT_REDIRECT_URI':
                'http://localhost:1455/auth/callback',
            'ADELE_OPENAI_CHATGPT_ENDPOINT': 'http://127.0.0.1:1/responses',
          },
        );
        addTearDown(host.close);
        final CapabilityRegistry registry = CapabilityRegistry();
        final DevelopmentSelfHostingProviderActivation activation =
            await activateDevelopmentSelfHostingModelProvider(
              host: host,
              registry: registry,
              artifact: pluginArtifact,
              profile: fixture.profile,
            );
        addTearDown(activation.close);
        expect(
          registry
              .providersFor(modelProviderCapability)
              .map((provider) => provider.id.value),
          unorderedEquals([
            if (fixture.apiKey) developmentSelfHostingApiKeyProviderId,
            if (fixture.chatGpt) developmentSelfHostingChatGptProviderId,
          ]),
        );
        final ProviderBinding selected = registry.resolve(
          modelProviderCapability,
          providerId: ProviderId(fixture.profile.providerId),
        );
        expect(selected.provider.id.value, fixture.profile.providerId);
        expect(() => selected.streamChannel, returnsNormally);
        await activation.close();
        expect(registry.providersFor(modelProviderCapability), isEmpty);
        expect(
          () => selected.streamChannel,
          throwsA(isA<ProviderUnavailable>()),
        );
        expect(host.isClosed, isFalse);
      });
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
