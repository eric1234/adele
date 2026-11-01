@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_plugin_backend_support/adele_backend_credentials.dart';
import 'package:openai_model_provider_backend/openai_model_provider_backend.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory artifacts;
  late String runtime;
  late File hostArtifact;
  late File pluginArtifact;

  setUpAll(() async {
    final String repository =
        Directory.current.parent.parent.parent.parent.path;
    artifacts = Directory(
      '$repository/.dart_tool/adele/integration/openai-configuration-contexts',
    )..createSync(recursive: true);
    final String dart = Platform.resolvedExecutable;
    runtime = '${File(dart).parent.path}/dartaotruntime';
    hostArtifact = File('${artifacts.path}/host.aot');
    pluginArtifact = File('${artifacts.path}/openai.aot');
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
  });

  Future<_ConfiguredFixture> configured({bool chatGpt = false}) =>
      _ConfiguredFixture.start(
        runtime: runtime,
        hostArtifact: hostArtifact,
        pluginArtifact: pluginArtifact,
        artifacts: artifacts,
        chatGpt: chatGpt,
      );

  test(
    'AOT configuration isolates API key, ChatGPT-only, and combined contexts',
    () async {
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

  test(
    'AOT records have independent lazy credentials, routes, and ChatGPT context',
    () async {
      final fixture = await configured(chatGpt: true);
      final connection = fixture.connection;
      final exposures = connection.capabilityExposures;
      expect(
        exposures
            .where((entry) => entry.providerId != openAiChatGptProviderId)
            .map((entry) => entry.toMap()),
        [
          for (final (id, name) in [
            ('personal-openai', 'Personal OpenAI'),
            ('work-openai', 'Work OpenAI'),
          ])
            AdeleCapabilityExposure(
              providerId: 'dev.adele.openai.api-key.$id',
              capabilityId: modelProviderCapability.id.value,
              capabilityMajorVersion: modelProviderCapability.majorVersion,
              serviceId: modelProviderServiceId,
              displayName: name,
              configurationContext: 'api-key-record:$id',
            ).toMap(),
        ],
      );
      expect(exposures, hasLength(3));
      expect(
        exposures
            .singleWhere((entry) => entry.providerId == openAiChatGptProviderId)
            .configurationContext,
        openAiChatGptConfigurationContext,
      );
      expect(fixture.credentials.requests, isEmpty);
      expect(fixture.responses.captured, isEmpty);
      for (final id in ['work-openai', 'personal-openai']) {
        final binding = fixture.registry.resolve(
          modelProviderCapability,
          providerId: ProviderId('dev.adele.openai.api-key.$id'),
        );
        expect(fixture.activation.owns(binding), isTrue);
        expect(fixture.activation.connection, same(connection));
      }

      // Neither a stream value nor the other account's model/input selects a key.
      final lazyWork = fixture
          .client('work-openai')
          .invoke(_request('api-key-record:personal-openai'));
      expect(fixture.credentials.requests, isEmpty);
      _expectCompleted(await lazyWork.toList(), '/work/responses');
      expect(fixture.credentials.requests, [
        _credentialSelectors('work-openai'),
      ]);
      _expectCompleted(
        await fixture
            .client('personal-openai')
            .invoke(_request('api-key-record:work-openai'))
            .toList(),
        '/personal/responses',
      );
      _expectCompleted(
        await fixture.chatGpt
            .invoke(_request('api-key-record:work-openai'))
            .toList(),
        '/chatgpt/responses',
      );
      expect(fixture.credentials.requests, [
        _credentialSelectors('work-openai'),
        _credentialSelectors('personal-openai'),
      ]);
      expect(fixture.responses.captured, const [
        _CapturedRequest(
          path: '/work/responses',
          authorization: 'Bearer test-work-key',
          accountId: null,
          model: 'api-key-record:personal-openai',
        ),
        _CapturedRequest(
          path: '/personal/responses',
          authorization: 'Bearer test-personal-key',
          accountId: null,
          model: 'api-key-record:work-openai',
        ),
        _CapturedRequest(
          path: '/chatgpt/responses',
          authorization: 'Bearer oauth-configured-only',
          accountId: 'account-configured',
          model: 'api-key-record:work-openai',
        ),
      ]);

      for (final (context, service, code) in [
        (
          'default',
          modelProviderServiceId,
          'configuration_context_unavailable',
        ),
        (
          'api-key-record:unknown',
          modelProviderServiceId,
          'configuration_context_unavailable',
        ),
        ('api-key-record:work-openai', 'wrong-service', 'service_unavailable'),
        (
          'api-key-record:personal-openai',
          'wrong-service',
          'service_unavailable',
        ),
      ]) {
        await expectLater(
          ModelProviderServiceClient(
            connection.channelFor(
              connection.configurationContext(context),
              service,
            ),
          ).invoke(_request('not-called')).toList(),
          throwsA(
            isA<PluginRemoteFailure>().having(
              (error) => error.code,
              'code',
              code,
            ),
          ),
        );
      }
      expect(fixture.credentials.requests, hasLength(2));
      expect(fixture.responses.captured, hasLength(3));

      for (final (failure, code) in [
        ('notAuthorized', 'not_authorized'),
        ('notConfigured', 'not_configured'),
        ('missingLocally', 'missing_locally'),
        ('storageUnavailable', 'storage_unavailable'),
        ('invalidCredentialBinding', 'invalid_binding'),
        ('reconciliationRequired', 'reconciliation_required'),
        ('staleConfiguration', 'stale_configuration'),
        ('generationUnavailable', 'generation_unavailable'),
        ('credentialAccessFailed', 'access_failed'),
      ]) {
        fixture.credentials.responses['work-openai'] = {'failure': failure};
        final events = await fixture
            .client('work-openai')
            .invoke(_request('no-fallback'))
            .toList();
        expect(events, hasLength(1));
        expect(events.single.kind, ModelProviderEventKind.terminal);
        expect(
          events.single.terminal?.settlement,
          ModelProviderSettlement.failed,
        );
        expect(
          events.single.terminal?.failure?.providerCode,
          'openai_credential_$code',
        );
        final terminal = events.single.terminal!;
        expect(
          terminal.failure?.kind,
          isNot(ModelProviderFailureKind.authentication),
        );
        expect(terminal.nativeState, isNull);
        expect(terminal.affinityState, isNull);
        expect(terminal.usage, isNull);
        fixture.expectRedacted([
          terminal.failure?.providerCode,
          terminal.failure?.providerMessage,
          terminal.failure?.providerDetails,
          terminal.providerStopReason,
          terminal.effectiveModel,
          terminal.responseId,
          terminal.requestId,
        ]);
      }
      expect(fixture.responses.captured, hasLength(3));
      _expectCompleted(
        await fixture
            .client('personal-openai')
            .invoke(_request('still-personal'))
            .toList(),
        '/personal/responses',
      );
      _expectCompleted(
        await fixture.chatGpt.invoke(_request('still-chatgpt')).toList(),
        '/chatgpt/responses',
      );
      expect(
        fixture.responses.captured
            .skip(3)
            .map((request) => request.authorization),
        ['Bearer test-personal-key', 'Bearer oauth-configured-only'],
      );
      expect(
        fixture.credentials.requests.last,
        _credentialSelectors('personal-openai'),
      );
      fixture.expectRedacted(exposures.map((entry) => entry.toMap()).toList());
      fixture.expectRedacted(fixture.responses.bodies);
      fixture.expectRedacted(fixture.diagnostics);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'AOT configured streams cancel pending reads and SSE independently, pause, and retire',
    () async {
      final fixture = await configured();
      expect(fixture.connection.capabilityExposures, hasLength(2));
      expect(fixture.credentials.requests, isEmpty);

      final pending = _CredentialGate();
      fixture.credentials.gates['work-openai'] = pending;
      final cancelledEvents = <ModelProviderEvent>[];
      final subscription = fixture
          .client('work-openai')
          .invoke(_request('cancel-before-key'))
          .listen(cancelledEvents.add);
      addTearDown(subscription.cancel);
      await pending.entered.future;
      expect(fixture.responses.captured, isEmpty);
      // A sibling completes while the first route is waiting on host credentials.
      _expectCompleted(
        await fixture
            .client('personal-openai')
            .invoke(_request('while-key-pending'))
            .toList(),
        '/personal/responses',
      );
      await subscription.cancel().timeout(const Duration(seconds: 5));
      pending.release.complete();
      await pending.returned.future;
      _expectCompleted(
        await fixture
            .client('personal-openai')
            .invoke(_request('after-cancel-barrier'))
            .toList(),
        '/personal/responses',
      );
      expect(cancelledEvents, isEmpty);
      expect(fixture.responses.captured.map((request) => request.path), [
        '/personal/responses',
        '/personal/responses',
      ]);

      final workSse = fixture.responses.hold('work-active');
      final personalSse = fixture.responses.hold('personal-active');
      final workEvents = <ModelProviderEvent>[];
      final personalEvents = <ModelProviderEvent>[];
      final workFirst = Completer<void>();
      final personalFirst = Completer<void>();
      final personalDone = Completer<void>();
      late StreamSubscription<ModelProviderEvent> work;
      late StreamSubscription<ModelProviderEvent> personal;
      work = fixture
          .client('work-openai')
          .invoke(_request('work-active'))
          .listen((event) {
            workEvents.add(event);
            if (!workFirst.isCompleted) {
              work.pause();
              workFirst.complete();
            }
          });
      personal = fixture
          .client('personal-openai')
          .invoke(_request('personal-active'))
          .listen((event) {
            personalEvents.add(event);
            if (!personalFirst.isCompleted) {
              personal.pause();
              personalFirst.complete();
            }
          }, onDone: personalDone.complete);
      addTearDown(work.cancel);
      addTearDown(personal.cancel);
      await Future.wait([workFirst.future, personalFirst.future]);
      expect(workEvents.single.kind, ModelProviderEventKind.observation);
      expect(personalEvents.single.kind, ModelProviderEventKind.observation);
      await personalSse.complete('/personal/responses');
      _expectCompleted(
        await fixture
            .client('work-openai')
            .invoke(_request('while-streams-paused'))
            .toList(),
        '/work/responses',
      );
      expect(workEvents, hasLength(1));
      expect(personalEvents, hasLength(1));
      await work.cancel().timeout(const Duration(seconds: 5));
      await workSse.closed.future.timeout(const Duration(seconds: 5));
      personal.resume();
      await personalDone.future;
      expect(workEvents, hasLength(1));
      _expectCompleted(personalEvents.skip(1).toList(), '/personal/responses');
      expect(
        fixture.responses.captured
            .where((request) => request.model == 'work-active')
            .single
            .authorization,
        'Bearer test-work-key',
      );
      expect(
        fixture.responses.captured
            .where((request) => request.model == 'personal-active')
            .single
            .authorization,
        'Bearer test-personal-key',
      );

      final retiring = _CredentialGate();
      fixture.credentials.gates['work-openai'] = retiring;
      final retiringSse = fixture.responses.hold('retired-during-sse');
      final retiringSseFirst = Completer<void>();
      final retiringSseDone = Completer<void>();
      final retiringSseEvents = <ModelProviderEvent>[];
      final retiringSseErrors = <Object>[];
      final retiringStream = fixture
          .client('personal-openai')
          .invoke(_request('retired-during-sse'))
          .listen(
            (event) {
              retiringSseEvents.add(event);
              if (!retiringSseFirst.isCompleted) retiringSseFirst.complete();
            },
            onError: retiringSseErrors.add,
            onDone: retiringSseDone.complete,
          );
      addTearDown(retiringStream.cancel);
      await retiringSseFirst.future;
      final retiredConnection = fixture.connection;
      final retiredContext = retiredConnection.configurationContext(
        'api-key-record:work-openai',
      );
      final retiredClient = fixture.client('work-openai');
      final retiredEvents = <ModelProviderEvent>[];
      final retiredErrors = <Object>[];
      final retiredDone = Completer<void>();
      retiredClient
          .invoke(_request('retired-before-key'))
          .listen(
            retiredEvents.add,
            onError: retiredErrors.add,
            onDone: retiredDone.complete,
          );
      await retiring.entered.future;
      final httpBeforeRetirement = fixture.responses.captured.length;
      await retiredConnection.close().timeout(const Duration(seconds: 5));
      await Future.wait([
        retiredDone.future,
        retiringSseDone.future,
        retiringSse.closed.future,
      ]).timeout(const Duration(seconds: 5));
      // A terminal item can replenish credit after _stopPlugin removes the
      // isolate. That exact host rejection may arrive before local stop settles
      // the stream; contract/router failures are not retirement outcomes.
      final retirementError = anyOf(
        isA<PluginConnectionClosed>().having(
          (error) => error.message,
          'message',
          'Plugin $openAiPluginId was stopped.',
        ),
        isA<PluginRemoteFailure>()
            .having((error) => error.code, 'code', 'host_command_failed')
            .having(
              (error) => error.message,
              'message',
              'Bad state: Plugin $openAiPluginId is not running.',
            )
            .having((error) => error.details, 'details', isEmpty)
            .having(
              (error) => error.declaredFailureType,
              'declaredFailureType',
              isNull,
            ),
      );
      expect(retiringSseEvents.first.kind, ModelProviderEventKind.observation);
      expect(
        retiringSseEvents.where(
          (event) => event.kind == ModelProviderEventKind.terminal,
        ),
        hasLength(lessThanOrEqualTo(1)),
      );
      expect(retiringSseErrors, everyElement(retirementError));
      expect(retiringSseErrors.length, lessThanOrEqualTo(1));
      expect(
        retiredEvents.every(
          (event) => event.kind == ModelProviderEventKind.terminal,
        ),
        isTrue,
      );
      // Connection retirement may follow a semantic failure with transport
      // closure; it must not synthesize a second model-provider terminal.
      expect(retiredEvents, hasLength(lessThanOrEqualTo(1)));
      for (final event in retiredEvents) {
        expect(event.terminal?.settlement, ModelProviderSettlement.failed);
        expect(
          event.terminal?.failure?.providerCode,
          'openai_credential_generation_unavailable',
        );
      }
      expect(retiredErrors, everyElement(retirementError));
      expect(retiredErrors, hasLength(lessThanOrEqualTo(1)));
      expect(
        retiredEvents.length + retiredErrors.length,
        greaterThanOrEqualTo(1),
      );
      await fixture.activation.close();
      retiring.release.complete();
      await retiring.returned.future;

      // A fresh generation keeps semantic IDs but cannot accept the old context.
      fixture.records.first['values'] = {
        'display-name': 'Renamed Work',
        'endpoint': '${fixture.responses.origin}/work-new/responses',
      };
      fixture.credentials.responses['work-openai'] = {
        'secret': 'test-replacement-key',
      };
      final readsBeforeRestart = fixture.credentials.requests.length;
      await fixture.startGeneration();
      expect(fixture.credentials.requests, hasLength(readsBeforeRestart));
      expect(fixture.connection, isNot(same(retiredConnection)));
      expect(
        fixture.connection.capabilityExposures.map((entry) => entry.providerId),
        [
          'dev.adele.openai.api-key.personal-openai',
          'dev.adele.openai.api-key.work-openai',
        ],
      );
      expect(
        fixture.connection.capabilityExposures.last.displayName,
        'Renamed Work',
      );
      expect(
        () => fixture.connection.channelFor(
          retiredContext,
          modelProviderServiceId,
        ),
        throwsArgumentError,
      );
      await expectLater(
        retiredClient.invoke(_request('old-binding')).toList(),
        throwsA(isA<PluginConnectionClosed>()),
      );
      _expectCompleted(
        await fixture
            .client('work-openai')
            .invoke(_request('fresh-generation'))
            .toList(),
        '/work-new/responses',
      );
      expect(fixture.responses.captured, hasLength(httpBeforeRetirement + 1));
      expect(
        fixture.responses.captured.last.authorization,
        'Bearer test-replacement-key',
      );
      expect(
        fixture.responses.captured.any(
          (request) =>
              request.model == 'retired-before-key' ||
              request.model == 'cancel-before-key',
        ),
        isFalse,
      );
      fixture.expectRedacted(fixture.diagnostics);
    },
    timeout: const Timeout(Duration(minutes: 2)),
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
      affinity: null,
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

void _expectCompleted(List<ModelProviderEvent> events, String text) {
  expect(events.map((event) => event.kind), [
    ModelProviderEventKind.output,
    ModelProviderEventKind.terminal,
  ]);
  expect(events.first.output?.text, text);
  expect(events.last.terminal?.settlement, ModelProviderSettlement.completed);
  expect(events.last.terminal?.failure, isNull);
}

Map<String, Object?> _credentialSelectors(String id) => {
  'collection': 'providers',
  'recordType': 'dev.adele.openai.api-key',
  'recordId': id,
  'slot': 'api-key',
};

final class _ConfiguredFixture {
  _ConfiguredFixture({
    required this.host,
    required this.pluginArtifact,
    required this.responses,
    required this.credentials,
    required this.arguments,
    required this.diagnostics,
  }) : records = [
         // Deliberately unsorted input; advertisements use stable record IDs.
         for (final (id, name, path) in [
           ('work-openai', 'Work OpenAI', '/work/responses'),
           ('personal-openai', 'Personal OpenAI', '/personal/responses'),
         ])
           {
             'collection': 'providers',
             'type': 'dev.adele.openai.api-key',
             'id': id,
             'values': {
               'display-name': name,
               'endpoint': '${responses.origin}$path',
             },
           },
       ];

  final PluginBackendHost host;
  final File pluginArtifact;
  final _ControlledResponses responses;
  final _CredentialDispatcher credentials;
  final List<String> arguments;
  final List<String> diagnostics;
  final List<Map<String, Object?>> records;
  final CapabilityRegistry registry = CapabilityRegistry();
  late PluginBackendConnection connection;
  late PluginCapabilityActivation activation;

  static Future<_ConfiguredFixture> start({
    required String runtime,
    required File hostArtifact,
    required File pluginArtifact,
    required Directory artifacts,
    required bool chatGpt,
  }) async {
    final responses = await _ControlledResponses.start();
    addTearDown(responses.close);
    final credentials = _CredentialDispatcher();
    addTearDown(credentials.close);
    final credentialFile = File('${artifacts.path}/configured-chatgpt.json');
    await credentialFile.writeAsString(
      jsonEncode({
        'version': 1,
        'instances': {
          'configured-chatgpt': {
            'revision': 1,
            'credential': {
              'idToken': _idToken('account-configured'),
              'accessToken': 'oauth-configured-only',
              'refreshToken': 'refresh-configured-only',
              'accountId': 'account-configured',
              'fedRamp': false,
            },
          },
        },
      }),
    );
    final diagnostics = <String>[];
    final host = await PluginBackendHost.start(
      dartaotruntimeExecutable: runtime,
      hostArtifactPath: hostArtifact.path,
      environment: {
        'OPENAI_API_KEY': 'inherited-key-must-not-be-used',
        'ADELE_OPENAI_ENDPOINT': 'invalid-inherited-endpoint',
        'ADELE_OPENAI_CHATGPT_CLIENT_ID': '',
        'ADELE_OPENAI_CHATGPT_EXPERIMENTAL_CODEX_CLIENT': '',
      },
      onDiagnostic: diagnostics.add,
    );
    addTearDown(() async {
      if (!host.isClosed) await host.close(graceful: false);
    });
    final fixture = _ConfiguredFixture(
      host: host,
      pluginArtifact: pluginArtifact,
      responses: responses,
      credentials: credentials,
      diagnostics: diagnostics,
      arguments: chatGpt
          ? [
              '--chatgpt-only',
              jsonEncode({
                'credentialFile': credentialFile.path,
                'clientId': 'authorized-configured-test-client',
                'instanceId': 'configured-chatgpt',
                'endpoint': '${responses.origin}/chatgpt/responses',
              }),
            ]
          : [],
    );
    await fixture.startGeneration();
    return fixture;
  }

  Future<void> startGeneration() async {
    connection = await host.startPlugin(
      pluginId: openAiPluginId,
      artifactUri: pluginArtifact.uri,
      startupArgumentsOnly: true,
      arguments: arguments,
      records: records,
      createInfrastructureServices: (connection) {
        credentials.validate = connection.validateInfrastructureContext;
        return {backendCredentialServiceId: credentials};
      },
    );
    activation = await PluginCapabilityActivation.registerAdvertised(
      connection: connection,
      registry: registry,
    );
    addTearDown(activation.close);
  }

  ModelProviderServiceClient client(String id) =>
      _client(registry, ProviderId('dev.adele.openai.api-key.$id'));

  ModelProviderServiceClient get chatGpt =>
      _client(registry, ProviderId(openAiChatGptProviderId));

  void expectRedacted(Object value) {
    final serialized = jsonEncode(value);
    for (final secret in [
      'test-work-key',
      'test-personal-key',
      'test-replacement-key',
      'oauth-configured-only',
      'refresh-configured-only',
      'inherited-key-must-not-be-used',
    ]) {
      expect(serialized, isNot(contains(secret)));
    }
    expect(serialized, isNot(contains('credentialReference')));
    expect(serialized, isNot(contains('hostInfrastructureContext')));
  }
}

final class _CredentialGate {
  final entered = Completer<void>();
  final release = Completer<void>();
  final returned = Completer<void>();
}

// Only host service responses are fixtures. The actual OpenAI entrypoint,
// AdeleCredentialClient, multiplexer, and shared-host framing remain in use.
final class _CredentialDispatcher implements AdeleBackendDispatcher {
  final requests = <Map<String, Object?>>[];
  final responses = <String, Map<String, Object?>>{
    'work-openai': {'secret': 'test-work-key'},
    'personal-openai': {'secret': 'test-personal-key'},
  };
  final gates = <String, _CredentialGate>{};
  final _pending = <_CredentialGate>{};
  late void Function() validate;

  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) async {
    validate();
    expect(request['kind'], 'request');
    expect(request['method'], 'readCredential');
    final payload = (request['payload']! as Map).cast<String, Object?>();
    final id = payload['recordId']! as String;
    expect(payload, _credentialSelectors(id));
    expect(responses, contains(id));
    requests.add(Map.of(payload));
    final response = Map<String, Object?>.of(responses[id]!);
    final gate = gates.remove(id);
    if (gate != null) {
      _pending.add(gate);
      gate.entered.complete();
      await gate.release.future;
      _pending.remove(gate);
      gate.returned.complete();
    }
    return {
      'kind': 'response',
      'requestId': request['requestId'],
      'ok': true,
      'payload': response,
    };
  }

  @override
  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?>) send,
  ) => throw StateError('Credential requests are unary.');

  @override
  Future<void> close() async {
    for (final gate in _pending.toList()) {
      if (!gate.release.isCompleted) gate.release.complete();
      await gate.returned.future;
    }
  }
}

final class _ControlledResponses {
  _ControlledResponses(this.server);

  final HttpServer server;
  final captured = <_CapturedRequest>[];
  final bodies = <Map<String, Object?>>[];
  final _gates = <String, _SseGate>{};
  late StreamSubscription<HttpRequest> _subscription;

  String get origin => 'http://${server.address.address}:${server.port}';

  static Future<_ControlledResponses> start() async {
    final responses = _ControlledResponses(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    responses._subscription = responses.server.listen((request) {
      unawaited(responses._respond(request));
    });
    return responses;
  }

  _SseGate hold(String model) => _gates[model] = _SseGate(model);

  Future<void> _respond(HttpRequest request) async {
    final body =
        jsonDecode(await utf8.decoder.bind(request).join())!
            as Map<String, Object?>;
    bodies.add(body);
    expect(body['parallel_tool_calls'], isTrue);
    expect(body['stream'], isTrue);
    expect(body['store'], isFalse);
    final model = body['model']! as String;
    captured.add(
      _CapturedRequest(
        path: request.uri.path,
        authorization: request.headers.value(HttpHeaders.authorizationHeader),
        accountId: request.headers.value('ChatGPT-Account-ID'),
        model: model,
      ),
    );
    final gate = _gates[model];
    if (gate != null) {
      await gate.attach(request);
      return;
    }
    request.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    for (final event in _completedResponse(request.uri.path, model)) {
      _sse(request.response, event);
    }
    await request.response.close();
  }

  Future<void> close() async {
    for (final gate in _gates.values) {
      gate.socket?.destroy();
    }
    await _subscription.cancel();
    await server.close(force: true);
  }
}

final class _SseGate {
  _SseGate(this.model);

  final String model;
  final closed = Completer<void>();
  Socket? socket;

  Future<void> attach(HttpRequest request) async {
    final connection = socket = await request.response.detachSocket(
      writeHeaders: false,
    );
    void finish() {
      if (!closed.isCompleted) closed.complete();
    }

    connection.listen((_) {}, onDone: finish, onError: (Object _) => finish());
    connection.add(
      utf8.encode(
        'HTTP/1.1 200 OK\r\n'
        'Content-Type: text/event-stream\r\n'
        'Connection: close\r\n\r\n'
        'data: {"type":"response.output_text.delta","delta":"first"}\n\n',
      ),
    );
    await connection.flush();
  }

  Future<void> complete(String text) async {
    final connection = socket!;
    for (final event in _completedResponse(text, model)) {
      connection.add(utf8.encode('data: ${jsonEncode(event)}\n\n'));
    }
    await connection.flush();
    await connection.close();
  }
}

List<Map<String, Object?>> _completedResponse(String text, String model) => [
  {
    'type': 'response.output_item.done',
    'item': {
      'type': 'message',
      'id': 'message-$model',
      'role': 'assistant',
      'status': 'completed',
      'content': [
        {'type': 'output_text', 'text': text, 'annotations': <Object?>[]},
      ],
    },
  },
  {
    'type': 'response.completed',
    'response': {'id': 'response-$model', 'model': model},
  },
];
