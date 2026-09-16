import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:openai_model_provider_backend/openai_model_provider_backend.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

void main() {
  test(
    'AOT configuration isolates API key, ChatGPT-only, and combined contexts',
    () async {
      final String repository =
          Directory.current.parent.parent.parent.parent.path;
      final Directory artifacts = Directory(
        '$repository/.dart_tool/adele/integration/openai-configuration-contexts',
      )..createSync(recursive: true);
      final String dart = Platform.resolvedExecutable;
      final String runtime = '${File(dart).parent.path}/dartaotruntime';
      final File hostArtifact = File('${artifacts.path}/host.aot');
      final File pluginArtifact = File('${artifacts.path}/openai.aot');
      await Future.wait<void>(<Future<void>>[
        _compile(
          dart,
          '$repository/packages/plugin_backend_host/bin/adele_backend_host.dart',
          hostArtifact.path,
          repository,
        ),
        _compile(
          dart,
          '$repository/plugins/openai/packages/backend/bin/openai_model_provider_backend.dart',
          pluginArtifact.path,
          repository,
        ),
      ]);
      final List<_CapturedRequest> captured = <_CapturedRequest>[];
      final HttpServer responses = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final StreamSubscription<HttpRequest> responseSubscription = responses
          .listen((HttpRequest request) {
            unawaited(() async {
              final Map<String, Object?> body =
                  jsonDecode(await utf8.decoder.bind(request).join())!
                      as Map<String, Object?>;
              expect(body['parallel_tool_calls'], isTrue);
              captured.add(
                _CapturedRequest(
                  path: request.uri.path,
                  authorization: request.headers.value(
                    HttpHeaders.authorizationHeader,
                  ),
                  accountId: request.headers.value('ChatGPT-Account-ID'),
                  model: body['model']! as String,
                ),
              );
              request.response.headers.contentType = ContentType(
                'text',
                'event-stream',
                charset: 'utf-8',
              );
              _sse(request.response, <String, Object?>{
                'type': 'response.output_item.done',
                'item': <String, Object?>{
                  'type': 'message',
                  'id': 'message-${captured.length}',
                  'role': 'assistant',
                  'status': 'completed',
                  'content': <Object?>[
                    <String, Object?>{
                      'type': 'output_text',
                      'text': request.uri.path,
                      'annotations': <Object?>[],
                    },
                  ],
                },
              });
              _sse(request.response, <String, Object?>{
                'type': 'response.completed',
                'response': <String, Object?>{
                  'id': 'response-${captured.length}',
                  'model': body['model'],
                },
              });
              await request.response.close();
            }());
          });
      addTearDown(() async {
        await responseSubscription.cancel();
        await responses.close(force: true);
      });
      final File credentials = File(
        '${artifacts.path}/chatgpt-credentials.json',
      );
      await credentials.writeAsString(
        jsonEncode(<String, Object?>{
          'version': 1,
          'instances': <String, Object?>{
            'aot-chatgpt': <String, Object?>{
              'revision': 1,
              'credential': <String, Object?>{
                'idToken': _idToken('account-aot'),
                'accessToken': 'oauth-aot-only',
                'refreshToken': 'refresh-aot-only',
                'accountId': 'account-aot',
                'fedRamp': false,
              },
            },
          },
        }),
        flush: true,
      );
      final String origin =
          'http://${responses.address.address}:${responses.port}';
      final PluginBackendHost apiOnlyHost = await PluginBackendHost.start(
        dartaotruntimeExecutable: runtime,
        hostArtifactPath: hostArtifact.path,
        environment: <String, String>{
          'OPENAI_API_KEY': 'api-key-aot-only',
          'ADELE_OPENAI_ENDPOINT': '$origin/public/responses',
          'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': credentials.path,
          'ADELE_OPENAI_CHATGPT_CLIENT_ID': '',
          'ADELE_OPENAI_CHATGPT_EXPERIMENTAL_CODEX_CLIENT': '',
        },
      );
      addTearDown(() async {
        if (!apiOnlyHost.isClosed) {
          await apiOnlyHost.close(graceful: false);
        }
      });
      final PluginBackendConnection apiOnlyConnection = await apiOnlyHost
          .startPlugin(
            pluginId: openAiPluginId,
            artifactUri: pluginArtifact.uri,
          );
      final CapabilityRegistry apiOnlyRegistry = CapabilityRegistry();
      final advertisedApiOnly =
          await PluginCapabilityActivation.registerAdvertised(
            connection: apiOnlyConnection,
            registry: apiOnlyRegistry,
          );
      expect(
        apiOnlyRegistry
            .providersFor(modelProviderCapability)
            .map((provider) => provider.id.value),
        [openAiApiKeyProviderId],
      );
      expect(
        apiOnlyConnection.capabilityExposures.single.configurationContext,
        'default',
      );
      final ProviderId unavailableChatGptProvider = ProviderId(
        openAiChatGptProviderId,
      );
      final PluginCapabilityActivation unavailableChatGptActivation =
          await PluginCapabilityActivation.register(
            connection: apiOnlyConnection,
            registry: apiOnlyRegistry,
            exposures: <PluginCapabilityExposure>[
              PluginCapabilityExposure(
                provider: _descriptor(unavailableChatGptProvider),
                configurationContext: apiOnlyConnection.configurationContext(
                  openAiChatGptConfigurationContext,
                ),
              ),
            ],
          );
      await expectLater(
        _client(
          apiOnlyRegistry,
          unavailableChatGptProvider,
        ).invoke(_request('unavailable-chatgpt')).toList(),
        throwsA(
          isA<PluginRemoteFailure>().having(
            (error) => error.code,
            'code',
            'configuration_context_unavailable',
          ),
        ),
      );
      await unavailableChatGptActivation.close();
      await advertisedApiOnly.close();
      await apiOnlyConnection.close();
      await apiOnlyHost.close();

      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: runtime,
        hostArtifactPath: hostArtifact.path,
        environment: <String, String>{
          'OPENAI_API_KEY': 'api-key-aot-only',
          'ADELE_OPENAI_ENDPOINT': '$origin/public/responses',
          'ADELE_OPENAI_CHATGPT_ENDPOINT': '$origin/chatgpt/responses',
          'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': credentials.path,
          'ADELE_OPENAI_CHATGPT_CLIENT_ID': 'authorized-aot-test-client',
          'ADELE_OPENAI_CHATGPT_INSTANCE_ID': 'aot-chatgpt',
          'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER': origin,
          'ADELE_OPENAI_CHATGPT_REDIRECT_URI':
              'http://127.0.0.1:1455/auth/callback',
        },
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final preparedWithoutArguments = await host.startPlugin(
        pluginId: openAiPluginId,
        artifactUri: pluginArtifact.uri,
        startupArgumentsOnly: true,
      );
      expect(preparedWithoutArguments.capabilityExposures, isEmpty);
      await preparedWithoutArguments.close();
      // The same host still supports direct/self-hosting environment configuration.
      final PluginBackendConnection connection = await host.startPlugin(
        pluginId: openAiPluginId,
        artifactUri: pluginArtifact.uri,
      );
      final CapabilityRegistry registry = CapabilityRegistry();
      final ConfigurationContextId apiKeyContext =
          connection.defaultConfigurationContext;
      final ConfigurationContextId chatGptContext = connection
          .configurationContext(openAiChatGptConfigurationContext);
      final ProviderId apiKeyProvider = ProviderId(openAiApiKeyProviderId);
      final ProviderId chatGptProvider = ProviderId(openAiChatGptProviderId);
      final PluginCapabilityActivation activation =
          await PluginCapabilityActivation.registerAdvertised(
            connection: connection,
            registry: registry,
          );
      addTearDown(activation.close);
      expect(
        registry
            .providersFor(modelProviderCapability)
            .map((provider) => provider.id.value),
        [openAiApiKeyProviderId, openAiChatGptProviderId],
      );

      final List<ModelProviderEvent> apiKeyEvents = await _client(
        registry,
        apiKeyProvider,
      ).invoke(_request(openAiChatGptConfigurationContext)).toList();
      final List<ModelProviderEvent> chatGptEvents = await _client(
        registry,
        chatGptProvider,
      ).invoke(_request('default')).toList();
      expect(apiKeyEvents.first.output?.text, '/public/responses');
      expect(chatGptEvents.first.output?.text, '/chatgpt/responses');
      expect(captured, <_CapturedRequest>[
        const _CapturedRequest(
          path: '/public/responses',
          authorization: 'Bearer api-key-aot-only',
          accountId: null,
          model: openAiChatGptConfigurationContext,
        ),
        const _CapturedRequest(
          path: '/chatgpt/responses',
          authorization: 'Bearer oauth-aot-only',
          accountId: 'account-aot',
          model: 'default',
        ),
      ]);
      expect(apiKeyProvider, isNot(chatGptProvider));
      expect(apiKeyContext, isNot(chatGptContext));
      expect(
        () => connection.channelFor(apiKeyContext, 'wrong-service'),
        returnsNormally,
      );

      await activation.close();
      await host.close();

      for (final mode in [
        (startup: false, apiKey: '', experimental: false),
        (startup: false, apiKey: '  ', experimental: true),
        (startup: true, apiKey: '', experimental: false),
        (startup: true, apiKey: 'inherited-api-key', experimental: true),
      ]) {
        final PluginBackendHost chatOnlyHost = await PluginBackendHost.start(
          dartaotruntimeExecutable: runtime,
          hostArtifactPath: hostArtifact.path,
          environment: <String, String>{
            'OPENAI_API_KEY': mode.apiKey,
            'ADELE_OPENAI_ENDPOINT': 'invalid-inherited-api-endpoint',
            'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': credentials.path,
            'ADELE_OPENAI_CHATGPT_CLIENT_ID': mode.experimental
                ? ''
                : 'authorized-aot-test-client',
            'ADELE_OPENAI_CHATGPT_EXPERIMENTAL_CODEX_CLIENT':
                mode.experimental && !mode.startup ? '1' : '',
            'ADELE_OPENAI_CHATGPT_INSTANCE_ID': 'aot-chatgpt',
            'ADELE_OPENAI_CHATGPT_ENDPOINT': mode.startup
                ? 'invalid-inherited-chatgpt-endpoint'
                : '$origin/chatgpt/responses',
            'ADELE_OPENAI_CHATGPT_OAUTH_ISSUER': origin,
            'ADELE_OPENAI_CHATGPT_REDIRECT_URI':
                'http://127.0.0.1:1455/auth/callback',
          },
        );
        addTearDown(chatOnlyHost.close);
        final PluginBackendConnection chatOnly = await chatOnlyHost.startPlugin(
          pluginId: openAiPluginId,
          artifactUri: pluginArtifact.uri,
          startupArgumentsOnly: mode.startup,
          arguments: mode.startup
              ? <String>[
                  '--chatgpt-only',
                  jsonEncode(<String, Object?>{
                    'credentialFile': credentials.path,
                    if (mode.experimental)
                      'experimentalCodexClient': true
                    else
                      'clientId': 'authorized-aot-test-client',
                    'instanceId': 'aot-chatgpt',
                    'endpoint': '$origin/chatgpt/responses',
                  }),
                ]
              : const <String>[],
        );
        final chatOnlyRegistry = CapabilityRegistry();
        final chatOnlyActivation =
            await PluginCapabilityActivation.registerAdvertised(
              connection: chatOnly,
              registry: chatOnlyRegistry,
            );
        expect(
          chatOnlyRegistry
              .providersFor(modelProviderCapability)
              .map((provider) => provider.id.value),
          [openAiChatGptProviderId],
        );
        expect(
          chatOnly.capabilityExposures.single.configurationContext,
          openAiChatGptConfigurationContext,
        );
        await expectLater(
          ModelProviderServiceClient(
            chatOnly.channelFor(
              chatOnly.defaultConfigurationContext,
              modelProviderServiceId,
            ),
          ).invoke(_request('unavailable-api-key')).toList(),
          throwsA(
            isA<PluginRemoteFailure>().having(
              (error) => error.code,
              'code',
              'configuration_context_unavailable',
            ),
          ),
        );
        final List<ModelProviderEvent> events =
            await ModelProviderServiceClient(
              chatOnly.channelFor(
                chatOnly.configurationContext(
                  openAiChatGptConfigurationContext,
                ),
                modelProviderServiceId,
              ),
            ).invoke(_request('gpt-6-astra')).toList();
        expect(events.first.output?.text, '/chatgpt/responses');
        expect(captured.last.authorization, 'Bearer oauth-aot-only');
        expect(captured.last.accountId, 'account-aot');
        expect(captured.last.model, 'gpt-6-astra');
        await chatOnly.close();
        await chatOnlyActivation.close();
        await chatOnlyHost.close();
      }

      final unconfiguredHost = await PluginBackendHost.start(
        dartaotruntimeExecutable: runtime,
        hostArtifactPath: hostArtifact.path,
        environment: <String, String>{
          'OPENAI_API_KEY': 'inherited-key-must-not-be-used',
          'ADELE_OPENAI_ENDPOINT': 'invalid-inherited-api-endpoint',
          'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': credentials.path,
          'ADELE_OPENAI_CHATGPT_CLIENT_ID': 'inherited-client',
          'ADELE_OPENAI_CHATGPT_EXPERIMENTAL_CODEX_CLIENT': '1',
          'ADELE_OPENAI_CHATGPT_ENDPOINT': 'invalid-inherited-chatgpt-endpoint',
        },
      );
      addTearDown(unconfiguredHost.close);
      for (final mode in [
        (arguments: const <String>[], startupArgumentsOnly: true),
        (arguments: const ['--chatgpt-only'], startupArgumentsOnly: false),
        (arguments: const ['--chatgpt-only'], startupArgumentsOnly: true),
      ]) {
        final unconfigured = await unconfiguredHost.startPlugin(
          pluginId: openAiPluginId,
          artifactUri: pluginArtifact.uri,
          arguments: mode.arguments,
          startupArgumentsOnly: mode.startupArgumentsOnly,
        );
        final emptyRegistry = CapabilityRegistry();
        final emptyActivation =
            await PluginCapabilityActivation.registerAdvertised(
              connection: unconfigured,
              registry: emptyRegistry,
            );
        expect(unconfigured.capabilityExposures, isEmpty);
        expect(emptyRegistry.providersFor(modelProviderCapability), isEmpty);
        final capturedBefore = captured.length;
        for (final context in ['default', openAiChatGptConfigurationContext]) {
          await expectLater(
            ModelProviderServiceClient(
              unconfigured.channelFor(
                unconfigured.configurationContext(context),
                modelProviderServiceId,
              ),
            ).invoke(_request('not-called')).toList(),
            throwsA(
              isA<PluginRemoteFailure>().having(
                (failure) => failure.code,
                'code',
                'configuration_context_unavailable',
              ),
            ),
          );
        }
        expect(captured, hasLength(capturedBefore));
        await emptyActivation.close();
      }
      await unconfiguredHost.close();

      final List<String> diagnostics = <String>[];
      final PluginBackendHost invalidHost = await PluginBackendHost.start(
        dartaotruntimeExecutable: runtime,
        hostArtifactPath: hostArtifact.path,
        environment: const <String, String>{
          'OPENAI_API_KEY': '',
          'ADELE_OPENAI_CHATGPT_CREDENTIAL_FILE': '',
          'ADELE_OPENAI_CHATGPT_CLIENT_ID': '',
          'ADELE_OPENAI_CHATGPT_EXPERIMENTAL_CODEX_CLIENT': '',
        },
        onDiagnostic: diagnostics.add,
      );
      addTearDown(invalidHost.close);
      await expectLater(
        invalidHost.startPlugin(
          pluginId: openAiPluginId,
          artifactUri: pluginArtifact.uri,
        ),
        throwsA(
          isA<PluginRemoteFailure>().having(
            (error) => error.message,
            'message',
            contains('requires a nonblank OPENAI_API_KEY'),
          ),
        ),
      );
      const String secret = 'sensitive-configuration-canary';
      final Map<String, Object?> valid = <String, Object?>{
        'credentialFile': credentials.path,
        'clientId': 'authorized-aot-test-client',
      };
      for (final List<String> arguments in <List<String>>[
        <String>['--unknown', secret],
        <String>['--chatgpt-only', '{"credentialFile":"$secret"'],
        <String>[
          '--chatgpt-only',
          jsonEncode(<Object?>[secret]),
        ],
        for (final Map<String, Object?> configuration in [
          <String, Object?>{},
          <String, Object?>{'credentialFile': credentials.path},
          <String, Object?>{...valid, 'accessToken': secret},
          <String, Object?>{...valid, 'apiKey': secret},
          <String, Object?>{
            ...valid,
            'credentialFile': <String>[secret],
          },
          <String, Object?>{...valid, 'credentialFile': ''},
          <String, Object?>{...valid, 'experimentalCodexClient': secret},
          <String, Object?>{...valid, 'clientId': '$secret\n'},
          <String, Object?>{...valid, 'endpoint': 'https://[$secret'},
          <String, Object?>{
            ...valid,
            'endpoint': 'http://example.test/$secret',
          },
          <String, Object?>{...valid, 'issuer': 'https://example.test/$secret'},
          <String, Object?>{
            ...valid,
            'redirectUri': 'https://example.test/$secret',
          },
          <String, Object?>{
            ...valid,
            'endpoint': 'https://$secret@example.test',
          },
        ])
          <String>['--chatgpt-only', jsonEncode(configuration)],
      ]) {
        await expectLater(
          invalidHost.startPlugin(
            pluginId: openAiPluginId,
            artifactUri: pluginArtifact.uri,
            arguments: arguments,
          ),
          throwsA(
            isA<PluginRemoteFailure>()
                .having(
                  (error) => error.message,
                  'message',
                  contains('Invalid OpenAI'),
                )
                .having(
                  (error) => error.toString(),
                  'redacted',
                  isNot(contains(secret)),
                ),
          ),
        );
      }
      await invalidHost.close();
      expect(diagnostics.join(), isNot(contains(secret)));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

ProviderDescriptor _descriptor(ProviderId id) => ProviderDescriptor(
  id: id,
  capability: modelProviderCapability,
  pluginId: openAiPluginId,
  displayName: id.value,
  serviceId: modelProviderServiceId,
);

ModelProviderServiceClient _client(
  CapabilityRegistry registry,
  ProviderId providerId,
) => ModelProviderServiceClient(
  registry
      .resolve(modelProviderCapability, providerId: providerId)
      .streamChannel,
);

ModelProviderRequest _request(String semanticRouteSpoof) =>
    ModelProviderRequest(
      model: semanticRouteSpoof,
      instructions: 'Route only through the binding-owned context.',
      input: <ModelProviderInput>[
        ModelProviderInput(
          kind: ModelProviderInputKind.message,
          message: ModelProviderMessage(
            role: ModelProviderMessageRole.user,
            content: <ModelProviderContent>[
              ModelProviderContent(
                kind: ModelProviderContentKind.text,
                text: semanticRouteSpoof,
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
    );

Future<void> _compile(
  String dart,
  String entrypoint,
  String output,
  String workingDirectory,
) async {
  final ProcessResult result = await Process.run(dart, <String>[
    'compile',
    'aot-snapshot',
    entrypoint,
    '-o',
    output,
  ], workingDirectory: workingDirectory);
  if (result.exitCode != 0) throw StateError(result.stderr.toString());
}

void _sse(HttpResponse response, Map<String, Object?> event) {
  response.write('data: ${jsonEncode(event)}\n\n');
}

String _idToken(String accountId) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode(<String, Object?>{'alg': 'none'})}.${encode(<String, Object?>{
    'https://api.openai.com/auth': <String, Object?>{'chatgpt_account_id': accountId},
  })}.';
}

final class _CapturedRequest {
  const _CapturedRequest({
    required this.path,
    required this.authorization,
    required this.accountId,
    required this.model,
  });

  final String path;
  final String? authorization;
  final String? accountId;
  final String model;

  @override
  bool operator ==(Object other) =>
      other is _CapturedRequest &&
      path == other.path &&
      authorization == other.authorization &&
      accountId == other.accountId &&
      model == other.model;

  @override
  int get hashCode => Object.hash(path, authorization, accountId, model);

  @override
  String toString() =>
      '_CapturedRequest($path, $authorization, $accountId, $model)';
}
