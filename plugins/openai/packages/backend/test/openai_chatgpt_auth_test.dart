import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:openai_model_provider_backend/src/openai_chatgpt_auth.dart';
import 'package:test/test.dart';

void main() {
  group('OpenAI browser OAuth', () {
    test('constructs unique state and correct PKCE S256 challenge', () {
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
      expect(
        query['code_challenge'],
        base64Url
            .encode(sha256.convert(ascii.encode(first.verifier)).bytes)
            .replaceAll('=', ''),
      );
      expect(first.state, isNot(second.state));
      expect(first.verifier, isNot(second.verifier));
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

        final Uri authorization = oauth.createAttempt().authorizationUri;
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
      },
    );

    test('rejects callback mismatch, errors, and missing code safely', () async {
      final OpenAiOAuthClient oauth = OpenAiOAuthClient(
        configuration: _configuration(Uri.parse('https://auth.example.test')),
      );
      addTearDown(oauth.close);
      final OpenAiOAuthAttempt attempt = oauth.createAttempt();

      await expectLater(
        oauth.complete(
          attempt,
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
      await expectLater(
        oauth.complete(
          attempt,
          Uri.parse(
            'http://localhost/callback?state=${attempt.state}&error=access_denied',
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
      await expectLater(
        oauth.complete(
          attempt,
          Uri.parse('http://localhost/callback?state=${attempt.state}'),
        ),
        throwsA(
          isA<OpenAiAuthenticationException>().having(
            (OpenAiAuthenticationException error) => error.message,
            'message',
            isNot(contains(attempt.state)),
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
        request.response.write(response);
        await request.response.close();
      });
      addTearDown(server.close);
      final OpenAiOAuthClient oauth = OpenAiOAuthClient(
        configuration: _configuration(server.origin),
      );
      addTearDown(oauth.close);
      final OpenAiOAuthAttempt attempt = oauth.createAttempt();
      Uri callback() => Uri.parse(
        'http://localhost/callback?state=${attempt.state}&code=code',
      );

      await expectLater(
        oauth.complete(attempt, callback()),
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
      });
      await expectLater(
        oauth.complete(attempt, callback()),
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
        expect(identical(firstA, firstB), isTrue);
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
