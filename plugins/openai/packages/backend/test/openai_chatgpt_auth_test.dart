import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:openai_model_provider_backend/src/openai_chatgpt_auth.dart';
import 'package:test/test.dart';

void main() {
  group('OpenAI ChatGPT environment', () {
    test('shares configured instance identity and gates Codex fallback', () {
      const Map<String, String> configured = <String, String>{
        'ADELE_OPENAI_CHATGPT_INSTANCE_ID': 'non-default-instance',
        'ADELE_OPENAI_CHATGPT_CLIENT_ID': 'registered-client',
      };
      expect(openAiChatGptInstanceId(configured), 'non-default-instance');
      expect(
        openAiOAuthClientIdentity(
          configured,
          allowDevelopmentFallback: false,
        ).clientId,
        'registered-client',
      );
      expect(
        () => openAiOAuthClientIdentity(
          const <String, String>{},
          allowDevelopmentFallback: false,
        ),
        throwsStateError,
      );
      expect(
        openAiOAuthClientIdentity(const <String, String>{
          openAiExperimentalCodexClientEnvironment: '1',
        }, allowDevelopmentFallback: false).experimentalCodexClient,
        isTrue,
      );
    });
  });

  group('OpenAI browser OAuth', () {
    test('constructs unique state and package-owned PKCE S256 fields', () {
      final OpenAiOAuthClient oauth = OpenAiOAuthClient(
        configuration: _configuration(Uri.parse('https://auth.example.test')),
        random: Random(1234),
      );
      addTearDown(oauth.close);

      final OpenAiOAuthAttempt first = oauth.createAttempt();
      final OpenAiOAuthAttempt second = oauth.createAttempt();
      final Map<String, String> query = first.authorizationUri.queryParameters;
      expect(first.authorizationUri.path, '/oauth/authorize');
      expect(query['response_type'], 'code');
      expect(query['client_id'], 'authorized-adele-test-client');
      expect(query['redirect_uri'], 'http://127.0.0.1:1455/auth/callback');
      expect(query['scope'], contains('offline_access'));
      expect(query['state'], first.state);
      expect(query['code_challenge_method'], 'S256');
      expect(query['code_challenge'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(first.state, isNot(second.state));
      expect(
        first.authorizationUri.queryParameters['code_challenge'],
        isNot(second.authorizationUri.queryParameters['code_challenge']),
      );
      first.close();
      second.close();
    });

    test(
      'supports the current experimental harness authorization parameters',
      () {
        final OpenAiOAuthClient oauth = OpenAiOAuthClient(
          configuration: OpenAiOAuthConfiguration(
            clientId: openAiExperimentalCodexOAuthClientId,
            redirectUri: Uri.parse('http://localhost:1455/auth/callback'),
            authorizationParameters: const <String, String>{
              'id_token_add_organizations': 'true',
              'codex_cli_simplified_flow': 'true',
              'originator': 'adele',
            },
          ),
          random: Random(4321),
        );
        addTearDown(oauth.close);

        final OpenAiOAuthAttempt attempt = oauth.createAttempt();
        final Uri authorization = attempt.authorizationUri;
        expect(
          authorization.queryParameters,
          containsPair('client_id', openAiExperimentalCodexOAuthClientId),
        );
        expect(
          authorization.queryParameters,
          containsPair('id_token_add_organizations', 'true'),
        );
        expect(
          authorization.queryParameters,
          containsPair('codex_cli_simplified_flow', 'true'),
        );
        expect(
          authorization.queryParameters,
          containsPair('originator', 'adele'),
        );
        expect(
          () => OpenAiOAuthConfiguration(
            clientId: openAiExperimentalCodexOAuthClientId,
            redirectUri: Uri.parse('http://localhost:1455/auth/callback'),
            authorizationParameters: const <String, String>{'state': 'spoofed'},
          ),
          throwsArgumentError,
        );
        attempt.close();
      },
    );

    test(
      'wrong-state loopback callback is non-terminal before valid callback',
      () async {
        final _Server tokenServer = await _Server.start((request) async {
          await request.drain<void>();
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, Object?>{
              'id_token': _idToken('account-after-stray'),
              'access_token': 'access-after-stray',
              'refresh_token': 'refresh-after-stray',
              'token_type': 'Bearer',
            }),
          );
          await request.response.close();
        });
        addTearDown(tokenServer.close);
        final int callbackPort = await _availableLoopbackPort();
        final OpenAiOAuthClient oauth = OpenAiOAuthClient(
          configuration: OpenAiOAuthConfiguration(
            clientId: 'authorized-adele-test-client',
            issuer: tokenServer.origin,
            redirectUri: Uri.parse(
              'http://127.0.0.1:$callbackPort/auth/callback',
            ),
          ),
        );
        addTearDown(oauth.close);
        final _WrongThenValidCallbackBrowser browser =
            _WrongThenValidCallbackBrowser();

        final OpenAiChatGptCredential credential = await oauth.loginInBrowser(
          browser,
        );

        expect(browser.wrongStateStatus, HttpStatus.badRequest);
        expect(browser.wrongPathStatus, HttpStatus.notFound);
        expect(browser.wrongStateBody, isNot(contains(browser.expectedState)));
        expect(credential.accountId, 'account-after-stray');
      },
    );

    test('rejects callback mismatch, errors, and missing code safely', () async {
      final OpenAiOAuthClient oauth = OpenAiOAuthClient(
        configuration: _configuration(Uri.parse('https://auth.example.test')),
      );
      addTearDown(oauth.close);
      final OpenAiOAuthAttempt mismatch = oauth.createAttempt();
      await expectLater(
        oauth.complete(
          mismatch,
          Uri.parse('http://localhost/callback?state=wrong&code=secret-code'),
        ),
        throwsA(
          isA<OpenAiAuthenticationException>().having(
            (OpenAiAuthenticationException error) => error.code,
            'code',
            'oauth_state_mismatch',
          ),
        ),
      );
      final OpenAiOAuthAttempt denied = oauth.createAttempt();
      await expectLater(
        oauth.complete(
          denied,
          Uri.parse(
            'http://localhost/callback?state=${denied.state}&error=access_denied',
          ),
        ),
        throwsA(
          isA<OpenAiAuthenticationException>().having(
            (OpenAiAuthenticationException error) => error.code,
            'code',
            'oauth_callback_error',
          ),
        ),
      );
      final OpenAiOAuthAttempt missing = oauth.createAttempt();
      await expectLater(
        oauth.complete(
          missing,
          Uri.parse('http://localhost/callback?state=${missing.state}'),
        ),
        throwsA(
          isA<OpenAiAuthenticationException>().having(
            (OpenAiAuthenticationException error) => error.message,
            'message',
            isNot(contains(missing.state)),
          ),
        ),
      );
    });

    test(
      'exchanges browser code and persists account-bound credentials',
      () async {
        late Map<String, String> exchange;
        final _Server tokenServer = await _Server.start((request) async {
          exchange = Uri.splitQueryString(
            await utf8.decoder.bind(request).join(),
          );
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, Object?>{
              'id_token': _idToken('account-browser'),
              'access_token': 'access-browser-secret',
              'refresh_token': 'refresh-browser-secret',
              'token_type': 'Bearer',
              'expires_in': 3600,
            }),
          );
          await request.response.close();
        });
        addTearDown(tokenServer.close);
        final HttpServer reservation = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final int callbackPort = reservation.port;
        await reservation.close();
        final OpenAiOAuthClient oauth = OpenAiOAuthClient(
          configuration: OpenAiOAuthConfiguration(
            clientId: 'authorized-adele-test-client',
            issuer: tokenServer.origin,
            redirectUri: Uri.parse(
              'http://127.0.0.1:$callbackPort/auth/callback',
            ),
          ),
        );
        addTearDown(oauth.close);
        final InMemoryOpenAiCredentialStore store =
            InMemoryOpenAiCredentialStore();
        final OpenAiChatGptAuth auth = OpenAiChatGptAuth(
          instanceId: 'browser-instance',
          store: store,
          oauth: oauth,
        );
        final _CallbackBrowser browser = _CallbackBrowser();

        final OpenAiChatGptCredential credential = await auth.loginInBrowser(
          browser,
        );
        expect(credential.accountId, 'account-browser');
        expect(exchange['grant_type'], 'authorization_code');
        expect(exchange['code'], 'test-authorization-code');
        expect(exchange['code_verifier'], isNotEmpty);
        final OpenAiCredentialState persisted = await store.load(
          'browser-instance',
        );
        expect(persisted.revision, 1);
        expect(persisted.credential?.accessToken, 'access-browser-secret');
        expect(browser.opened?.queryParameters['state'], isNotEmpty);
      },
    );

    test('rejects malformed token and ID-token account claims', () async {
      var response = 'not-json';
      final _Server server = await _Server.start((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(response);
        await request.response.close();
      });
      addTearDown(server.close);
      final OpenAiOAuthClient oauth = OpenAiOAuthClient(
        configuration: _configuration(server.origin),
      );
      addTearDown(oauth.close);
      Uri callback(OpenAiOAuthAttempt attempt) => Uri.parse(
        'http://localhost/callback?state=${attempt.state}&code=code',
      );

      final OpenAiOAuthAttempt malformed = oauth.createAttempt();
      await expectLater(
        oauth.complete(malformed, callback(malformed)),
        throwsA(
          isA<OpenAiAuthenticationException>().having(
            (OpenAiAuthenticationException error) => error.code,
            'code',
            'malformed_token_response',
          ),
        ),
      );
      response = jsonEncode(<String, Object?>{
        'id_token': _jwt(<String, Object?>{}),
        'access_token': 'access-secret-not-surfaced',
        'refresh_token': 'refresh-secret-not-surfaced',
        'token_type': 'Bearer',
      });
      final OpenAiOAuthAttempt invalidClaims = oauth.createAttempt();
      await expectLater(
        oauth.complete(invalidClaims, callback(invalidClaims)),
        throwsA(
          isA<OpenAiAuthenticationException>()
              .having(
                (OpenAiAuthenticationException error) => error.code,
                'code',
                'invalid_id_token',
              )
              .having(
                (OpenAiAuthenticationException error) => error.message,
                'message',
                allOf(
                  isNot(contains('access-secret-not-surfaced')),
                  isNot(contains('refresh-secret-not-surfaced')),
                ),
              ),
        ),
      );
    });
  });

  group('OpenAI credential stores', () {
    test(
      'loads, CAS updates, rejects stale CAS, and tombstones logout',
      () async {
        final InMemoryOpenAiCredentialStore store =
            InMemoryOpenAiCredentialStore();
        expect((await store.load('one')).revision, 0);
        final OpenAiCredentialState first = await store.compareAndSwap(
          'one',
          0,
          _credential('account-one', 'access-one', 'refresh-one'),
        );
        expect(first.revision, 1);
        final OpenAiCredentialState stale = await store.compareAndSwap(
          'one',
          0,
          _credential('account-other', 'access-other', 'refresh-other'),
        );
        expect(stale.revision, 1);
        expect(stale.credential?.accountId, 'account-one');
        final OpenAiCredentialState deleted = await store.delete('one', 1);
        expect(deleted.revision, 2);
        expect(deleted.credential, isNull);
        final OpenAiCredentialState staleAfterDelete = await store
            .compareAndSwap(
              'one',
              1,
              _credential('account-one', 'resurrected', 'resurrected'),
            );
        expect(staleAfterDelete.revision, 2);
        expect(staleAfterDelete.credential, isNull);
      },
    );

    test(
      'file store persists atomically and fails explicitly on corruption',
      () async {
        final Directory directory = await Directory.systemTemp.createTemp(
          'adele-openai-store-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final File file = File('${directory.path}/credentials.json');
        final FileOpenAiCredentialStore store = FileOpenAiCredentialStore(file);
        await store.compareAndSwap(
          'persistent',
          0,
          _credential('account-file', 'access-file', 'refresh-file'),
        );

        final OpenAiCredentialState reloaded = await FileOpenAiCredentialStore(
          file,
        ).load('persistent');
        expect(reloaded.revision, 1);
        expect(reloaded.credential?.accountId, 'account-file');
        if (!Platform.isWindows) {
          final ProcessResult mode = await Process.run('stat', <String>[
            '-c',
            '%a',
            file.path,
          ]);
          expect(mode.stdout.toString().trim(), '600');
        }

        await file.writeAsString('{corrupt');
        await expectLater(
          FileOpenAiCredentialStore(file).load('persistent'),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('file store serializes concurrent same-revision CAS', () async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'adele-openai-store-cas-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final FileOpenAiCredentialStore store = FileOpenAiCredentialStore(
        File('${directory.path}/credentials.json'),
      );
      final FileOpenAiCredentialStore competingStore =
          FileOpenAiCredentialStore(File('${directory.path}/credentials.json'));
      final OpenAiCredentialState initial = await store.compareAndSwap(
        'concurrent',
        0,
        _credential('account', 'initial', 'refresh-initial'),
      );

      final List<OpenAiCredentialState> results =
          await Future.wait(<Future<OpenAiCredentialState>>[
            competingStore.compareAndSwap(
              'concurrent',
              initial.revision,
              _credential('account', 'candidate-a', 'refresh-a'),
            ),
            store.compareAndSwap(
              'concurrent',
              initial.revision,
              _credential('account', 'candidate-b', 'refresh-b'),
            ),
          ]);

      expect(results.where((state) => state.committed), hasLength(1));
      expect(results.where((state) => !state.committed), hasLength(1));
      expect(results.every((state) => state.revision == 2), isTrue);
      final OpenAiCredentialState finalState = await store.load('concurrent');
      expect(finalState.revision, 2);
      expect(
        finalState.credential?.accessToken,
        results.singleWhere((state) => state.committed).credential?.accessToken,
      );
    });

    test('file-store tombstone wins against stale concurrent CAS', () async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'adele-openai-store-delete-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final FileOpenAiCredentialStore store = FileOpenAiCredentialStore(
        File('${directory.path}/credentials.json'),
      );
      await store.compareAndSwap(
        'logout-race',
        0,
        _credential('account', 'initial', 'refresh-initial'),
      );

      final Future<OpenAiCredentialState> deletion = store.delete(
        'logout-race',
        1,
      );
      final Future<OpenAiCredentialState> staleCas = store.compareAndSwap(
        'logout-race',
        1,
        _credential('account', 'resurrected', 'refresh-resurrected'),
      );
      final List<OpenAiCredentialState> results = await Future.wait(
        <Future<OpenAiCredentialState>>[deletion, staleCas],
      );

      expect(results.first.committed, isTrue);
      expect(results.last.committed, isFalse);
      final OpenAiCredentialState finalState = await store.load('logout-race');
      expect(finalState.revision, 2);
      expect(finalState.credential, isNull);
    });

    test('failed store commit does not publish credentials', () async {
      final _FailingStore store = _FailingStore();
      final OpenAiOAuthClient oauth = OpenAiOAuthClient(
        configuration: _configuration(Uri.parse('https://auth.example.test')),
      );
      addTearDown(oauth.close);
      final OpenAiChatGptAuth auth = OpenAiChatGptAuth(
        instanceId: 'failing',
        store: store,
        oauth: oauth,
      );

      await expectLater(
        auth.install(_credential('account', 'access', 'refresh')),
        throwsA(isA<FileSystemException>()),
      );
      expect((await store.load('failing')).credential, isNull);
    });
  });

  group('OpenAI refresh fencing', () {
    test(
      'rotates tokens, preserves omitted fields, and rejects account mismatch',
      () async {
        var response = <String, Object?>{'access_token': 'access-rotated'};
        final _Server server = await _Server.start((request) async {
          expect(request.headers.contentType?.mimeType, 'application/json');
          await request.drain<void>();
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(response));
          await request.response.close();
        });
        addTearDown(server.close);
        final InMemoryOpenAiCredentialStore store =
            InMemoryOpenAiCredentialStore();
        final OpenAiOAuthClient oauth = OpenAiOAuthClient(
          configuration: _configuration(server.origin),
        );
        addTearDown(oauth.close);
        final OpenAiChatGptAuth auth = OpenAiChatGptAuth(
          instanceId: 'refresh',
          store: store,
          oauth: oauth,
        );
        await auth.install(
          _credential('account-refresh', 'access-old', 'refresh-old'),
        );

        final OpenAiChatGptCredential refreshed = await auth.refresh();
        expect(refreshed.accessToken, 'access-rotated');
        expect(refreshed.refreshToken, 'refresh-old');
        expect(refreshed.idToken, _idToken('account-refresh'));
        response = <String, Object?>{
          'id_token': _idToken('account-other'),
          'refresh_token': 'refresh-other',
        };
        await expectLater(
          auth.refresh(),
          throwsA(
            isA<OpenAiAuthenticationException>().having(
              (OpenAiAuthenticationException error) => error.code,
              'code',
              'account_mismatch',
            ),
          ),
        );
        expect(
          (await store.load('refresh')).credential?.refreshToken,
          'refresh-old',
        );
        response = <String, Object?>{'access_token': 42};
        await expectLater(
          auth.refresh(),
          throwsA(
            isA<OpenAiAuthenticationException>().having(
              (OpenAiAuthenticationException error) => error.code,
              'code',
              'malformed_token_response',
            ),
          ),
        );
        expect((await store.load('refresh')).revision, 2);
        response = <String, Object?>{};
        await expectLater(
          auth.refresh(),
          throwsA(
            isA<OpenAiAuthenticationException>().having(
              (OpenAiAuthenticationException error) => error.code,
              'code',
              'malformed_token_response',
            ),
          ),
        );
        expect((await store.load('refresh')).revision, 2);
      },
    );

    test(
      'coalesces same instance while separate instances refresh independently',
      () async {
        final Completer<void> release = Completer<void>();
        var requests = 0;
        final _Server server = await _Server.start((request) async {
          requests++;
          final Map<String, Object?> body =
              jsonDecode(await utf8.decoder.bind(request).join())!
                  as Map<String, Object?>;
          await release.future;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, Object?>{
              'access_token': 'new-${body['refresh_token']}',
            }),
          );
          await request.response.close();
        });
        addTearDown(server.close);
        final InMemoryOpenAiCredentialStore store =
            InMemoryOpenAiCredentialStore();
        final OpenAiOAuthClient oauth = OpenAiOAuthClient(
          configuration: _configuration(server.origin),
        );
        addTearDown(oauth.close);
        OpenAiChatGptAuth owner(String id) =>
            OpenAiChatGptAuth(instanceId: id, store: store, oauth: oauth);
        final OpenAiChatGptAuth first = owner('first');
        final OpenAiChatGptAuth second = owner('second');
        await first.install(
          _credential('account-first', 'old', 'refresh-first'),
        );
        await second.install(
          _credential('account-second', 'old', 'refresh-second'),
        );

        final Future<OpenAiChatGptCredential> firstA = first.refresh();
        final Future<OpenAiChatGptCredential> firstB = first.refresh();
        final Future<OpenAiChatGptCredential> secondA = second.refresh();
        while (requests < 2) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(requests, 2);
        release.complete();
        await Future.wait(<Future<OpenAiChatGptCredential>>[
          firstA,
          firstB,
          secondA,
        ]);
        expect(
          (await store.load('first')).credential?.accessToken,
          'new-refresh-first',
        );
        expect(
          (await store.load('second')).credential?.accessToken,
          'new-refresh-second',
        );
      },
    );

    test(
      'stale refresh cannot overwrite logout, relogin, or account switch',
      () async {
        for (final String mutation in <String>['logout', 'relogin', 'switch']) {
          final Completer<void> started = Completer<void>();
          final Completer<void> release = Completer<void>();
          final _Server server = await _Server.start((request) async {
            await request.drain<void>();
            started.complete();
            await release.future;
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode(<String, Object?>{'access_token': 'stale-result'}),
            );
            await request.response.close();
          });
          final InMemoryOpenAiCredentialStore store =
              InMemoryOpenAiCredentialStore();
          final OpenAiOAuthClient oauth = OpenAiOAuthClient(
            configuration: _configuration(server.origin),
          );
          final OpenAiChatGptAuth auth = OpenAiChatGptAuth(
            instanceId: 'instance',
            store: store,
            oauth: oauth,
          );
          await auth.install(_credential('account-a', 'access-a', 'refresh-a'));
          final Future<OpenAiChatGptCredential> refresh = auth.refresh();
          await started.future;
          if (mutation == 'logout') {
            await auth.logout();
          } else {
            await auth.install(
              _credential(
                mutation == 'switch' ? 'account-b' : 'account-a',
                'new-login',
                'new-refresh',
              ),
            );
          }
          release.complete();
          await expectLater(
            refresh,
            throwsA(
              isA<OpenAiAuthenticationException>().having(
                (OpenAiAuthenticationException error) => error.code,
                'code',
                'stale_refresh',
              ),
            ),
            reason: mutation,
          );
          final OpenAiChatGptCredential? finalCredential = (await store.load(
            'instance',
          )).credential;
          if (mutation == 'logout') {
            expect(finalCredential, isNull);
          } else {
            expect(finalCredential?.accessToken, 'new-login');
            expect(
              finalCredential?.accountId,
              mutation == 'switch' ? 'account-b' : 'account-a',
            );
          }
          oauth.close();
          await server.close();
        }
      },
    );

    test('newer revision does not join an older in-flight refresh', () async {
      final Completer<void> oldRefreshStarted = Completer<void>();
      final Completer<void> releaseOldRefresh = Completer<void>();
      var requests = 0;
      final _Server server = await _Server.start((request) async {
        requests++;
        final Map<String, Object?> body =
            jsonDecode(await utf8.decoder.bind(request).join())!
                as Map<String, Object?>;
        if (requests == 1) {
          expect(body['refresh_token'], 'refresh-old');
          oldRefreshStarted.complete();
          await releaseOldRefresh.future;
        } else {
          expect(body['refresh_token'], 'refresh-new-login');
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{
            'access_token': requests == 1
                ? 'access-stale-result'
                : 'access-new-refreshed',
          }),
        );
        await request.response.close();
      });
      addTearDown(server.close);
      final InMemoryOpenAiCredentialStore store =
          InMemoryOpenAiCredentialStore();
      final OpenAiOAuthClient oauth = OpenAiOAuthClient(
        configuration: _configuration(server.origin),
      );
      addTearDown(oauth.close);
      final OpenAiChatGptAuth auth = OpenAiChatGptAuth(
        instanceId: 'revision-keyed-refresh',
        store: store,
        oauth: oauth,
      );
      await auth.install(_credential('account', 'access-old', 'refresh-old'));

      final Future<OpenAiChatGptCredential> oldRefresh = auth.refresh();
      await oldRefreshStarted.future;
      await auth.install(
        _credential('account', 'access-new-login', 'refresh-new-login'),
      );
      final Future<OpenAiChatGptCredential> newerRefresh = auth.refresh();
      releaseOldRefresh.complete();

      await expectLater(
        oldRefresh,
        throwsA(
          isA<OpenAiAuthenticationException>().having(
            (OpenAiAuthenticationException error) => error.code,
            'code',
            'stale_refresh',
          ),
        ),
      );
      final OpenAiChatGptCredential recovered = await newerRefresh;
      expect(recovered.accessToken, 'access-new-refreshed');
      expect((await store.load('revision-keyed-refresh')).revision, 3);
      expect(requests, 2);
    });
  });
}

OpenAiOAuthConfiguration _configuration(Uri issuer) => OpenAiOAuthConfiguration(
  clientId: 'authorized-adele-test-client',
  issuer: issuer,
  redirectUri: Uri.parse('http://127.0.0.1:1455/auth/callback'),
);

OpenAiChatGptCredential _credential(
  String accountId,
  String accessToken,
  String refreshToken,
) => OpenAiChatGptCredential(
  idToken: _idToken(accountId),
  accessToken: accessToken,
  refreshToken: refreshToken,
  accountId: accountId,
  fedRamp: false,
  expiresAt: null,
);

String _idToken(String accountId) => _jwt(<String, Object?>{
  'https://api.openai.com/auth': <String, Object?>{
    'chatgpt_account_id': accountId,
    'chatgpt_account_is_fedramp': false,
  },
});

String _jwt(Map<String, Object?> payload) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode(<String, Object?>{'alg': 'none'})}.${encode(payload)}.';
}

final class _CallbackBrowser implements OpenAiBrowserLauncher {
  Uri? opened;

  @override
  Future<void> open(Uri uri) async {
    opened = uri;
    unawaited(() async {
      final Uri callback = Uri.parse(uri.queryParameters['redirect_uri']!)
          .replace(
            queryParameters: <String, String>{
              'state': uri.queryParameters['state']!,
              'code': 'test-authorization-code',
            },
          );
      final HttpClient client = HttpClient();
      try {
        final HttpClientResponse response = await (await client.getUrl(
          callback,
        )).close();
        await response.drain<void>();
      } finally {
        client.close();
      }
    }());
  }
}

final class _WrongThenValidCallbackBrowser implements OpenAiBrowserLauncher {
  int? wrongPathStatus;
  int? wrongStateStatus;
  String? wrongStateBody;
  String? expectedState;

  @override
  Future<void> open(Uri uri) async {
    final Uri redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
    expectedState = uri.queryParameters['state'];
    unawaited(() async {
      final HttpClient client = HttpClient();
      try {
        final HttpClientResponse wrongPath = await (await client.getUrl(
          redirect.replace(path: '/unrelated'),
        )).close();
        wrongPathStatus = wrongPath.statusCode;
        await wrongPath.drain<void>();

        final HttpClientResponse wrongState = await (await client.getUrl(
          redirect.replace(
            queryParameters: const <String, String>{
              'state': 'incorrect-state',
              'code': 'stray-code',
            },
          ),
        )).close();
        wrongStateStatus = wrongState.statusCode;
        wrongStateBody = await utf8.decoder.bind(wrongState).join();

        final HttpClientResponse valid = await (await client.getUrl(
          redirect.replace(
            queryParameters: <String, String>{
              'state': expectedState!,
              'code': 'valid-code',
            },
          ),
        )).close();
        await valid.drain<void>();
      } finally {
        client.close();
      }
    }());
  }
}

Future<int> _availableLoopbackPort() async {
  final HttpServer reservation = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  final int port = reservation.port;
  await reservation.close();
  return port;
}

final class _FailingStore implements OpenAiCredentialStore {
  @override
  Future<OpenAiCredentialState> load(String instanceId) async =>
      const OpenAiCredentialState(0, null);

  @override
  Future<OpenAiCredentialState> compareAndSwap(
    String instanceId,
    int expectedRevision,
    OpenAiChatGptCredential credential,
  ) => throw const FileSystemException('simulated store failure');

  @override
  Future<OpenAiCredentialState> delete(
    String instanceId,
    int expectedRevision,
  ) => throw const FileSystemException('simulated store failure');
}

final class _Server {
  _Server(this.server, this.subscription);

  final HttpServer server;
  final StreamSubscription<HttpRequest> subscription;

  Uri get origin =>
      Uri.parse('http://${server.address.address}:${server.port}');

  static Future<_Server> start(
    Future<void> Function(HttpRequest request) handler,
  ) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final StreamSubscription<HttpRequest> subscription = server.listen(
      (HttpRequest request) => unawaited(handler(request)),
    );
    return _Server(server, subscription);
  }

  Future<void> close() async {
    await subscription.cancel();
    await server.close(force: true);
  }
}
