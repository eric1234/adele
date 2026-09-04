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
    'AOT generation isolates API key and routes configured contexts',
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
          await PluginCapabilityActivation.register(
            connection: connection,
            registry: registry,
            exposures: <PluginCapabilityExposure>[
              PluginCapabilityExposure(
                provider: _descriptor(apiKeyProvider),
                configurationContext: apiKeyContext,
              ),
              PluginCapabilityExposure(
                provider: _descriptor(chatGptProvider),
                configurationContext: chatGptContext,
              ),
            ],
          );
      addTearDown(activation.close);

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
