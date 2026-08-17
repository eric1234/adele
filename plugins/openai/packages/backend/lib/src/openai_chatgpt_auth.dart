import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Source-visible Codex public-client identity used by current third-party
/// harnesses. This is an experimental interoperability default, not an ADELE
/// OAuth registration or a stable OpenAI third-party contract.
const String openAiExperimentalCodexOAuthClientId =
    'app_EMoamEEZ73f0CkXaXp7hrann';

final class OpenAiChatGptCredential {
  const OpenAiChatGptCredential({
    required this.idToken,
    required this.accessToken,
    required this.refreshToken,
    required this.accountId,
    required this.fedRamp,
    required this.expiresAt,
  });

  final String idToken;
  final String accessToken;
  final String refreshToken;
  final String accountId;
  final bool fedRamp;
  final DateTime? expiresAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'idToken': idToken,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'accountId': accountId,
    'fedRamp': fedRamp,
    if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
  };

  static OpenAiChatGptCredential fromJson(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const FormatException('Credential record is not an object.');
    }
    final String idToken = _requiredSecret(value, 'idToken');
    final String accessToken = _requiredSecret(value, 'accessToken');
    final String refreshToken = _requiredSecret(value, 'refreshToken');
    final String accountId = _requiredHeaderValue(value, 'accountId');
    final Object? fedRamp = value['fedRamp'];
    if (fedRamp is! bool) {
      throw const FormatException('Credential FedRAMP state is invalid.');
    }
    DateTime? expiresAt;
    if (value['expiresAt'] case final String encoded) {
      expiresAt = DateTime.tryParse(encoded)?.toUtc();
      if (expiresAt == null) {
        throw const FormatException('Credential expiration is invalid.');
      }
    } else if (value['expiresAt'] != null) {
      throw const FormatException('Credential expiration is invalid.');
    }
    return OpenAiChatGptCredential(
      idToken: idToken,
      accessToken: accessToken,
      refreshToken: refreshToken,
      accountId: accountId,
      fedRamp: fedRamp,
      expiresAt: expiresAt,
    );
  }
}

final class OpenAiCredentialState {
  const OpenAiCredentialState(
    this.revision,
    this.credential, {
    this.committed = false,
  });

  final int revision;
  final OpenAiChatGptCredential? credential;
  final bool committed;
}

abstract interface class OpenAiCredentialStore {
  Future<OpenAiCredentialState> load(String instanceId);

  Future<OpenAiCredentialState> compareAndSwap(
    String instanceId,
    int expectedRevision,
    OpenAiChatGptCredential credential,
  );

  Future<OpenAiCredentialState> delete(String instanceId, int expectedRevision);
}

final class InMemoryOpenAiCredentialStore implements OpenAiCredentialStore {
  final Map<String, OpenAiCredentialState> _states =
      <String, OpenAiCredentialState>{};

  @override
  Future<OpenAiCredentialState> load(String instanceId) async =>
      _states[instanceId] ?? const OpenAiCredentialState(0, null);

  @override
  Future<OpenAiCredentialState> compareAndSwap(
    String instanceId,
    int expectedRevision,
    OpenAiChatGptCredential credential,
  ) async {
    final OpenAiCredentialState current = await load(instanceId);
    if (current.revision != expectedRevision) return current;
    final OpenAiCredentialState committed = OpenAiCredentialState(
      current.revision + 1,
      credential,
      committed: true,
    );
    _states[instanceId] = OpenAiCredentialState(
      committed.revision,
      committed.credential,
    );
    return committed;
  }

  @override
  Future<OpenAiCredentialState> delete(
    String instanceId,
    int expectedRevision,
  ) async {
    final OpenAiCredentialState current = await load(instanceId);
    if (current.revision != expectedRevision) return current;
    final OpenAiCredentialState committed = OpenAiCredentialState(
      current.revision + 1,
      null,
      committed: true,
    );
    _states[instanceId] = OpenAiCredentialState(committed.revision, null);
    return committed;
  }
}

/// Development-only, one-writer credential persistence for self-hosting.
final class FileOpenAiCredentialStore implements OpenAiCredentialStore {
  FileOpenAiCredentialStore(this.file);

  final File file;

  @override
  Future<OpenAiCredentialState> load(String instanceId) async {
    final Map<String, Object?> document = await _read();
    return _decodeState(document, instanceId);
  }

  @override
  Future<OpenAiCredentialState> compareAndSwap(
    String instanceId,
    int expectedRevision,
    OpenAiChatGptCredential credential,
  ) => _mutate(instanceId, expectedRevision, credential);

  @override
  Future<OpenAiCredentialState> delete(
    String instanceId,
    int expectedRevision,
  ) => _mutate(instanceId, expectedRevision, null);

  Future<OpenAiCredentialState> _mutate(
    String instanceId,
    int expectedRevision,
    OpenAiChatGptCredential? credential,
  ) async {
    final Map<String, Object?> document = await _read();
    final OpenAiCredentialState current = _decodeState(document, instanceId);
    if (current.revision != expectedRevision) return current;
    final OpenAiCredentialState committed = OpenAiCredentialState(
      current.revision + 1,
      credential,
      committed: true,
    );
    final Map<String, Object?> instances = Map<String, Object?>.from(
      document['instances']! as Map<String, Object?>,
    );
    instances[instanceId] = <String, Object?>{
      'revision': committed.revision,
      'credential': credential?.toJson(),
    };
    await _write(<String, Object?>{'version': 1, 'instances': instances});
    return committed;
  }

  Future<Map<String, Object?>> _read() async {
    if (!await file.exists()) {
      return <String, Object?>{'version': 1, 'instances': <String, Object?>{}};
    }
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?> ||
          decoded['version'] != 1 ||
          decoded['instances'] is! Map<String, Object?>) {
        throw const FormatException('Credential store has an invalid shape.');
      }
      return decoded;
    } on FileSystemException {
      rethrow;
    } on Object catch (error) {
      throw FormatException('OpenAI credential store is corrupt.', error);
    }
  }

  OpenAiCredentialState _decodeState(
    Map<String, Object?> document,
    String instanceId,
  ) {
    final Object? encoded =
        (document['instances']! as Map<String, Object?>)[instanceId];
    if (encoded == null) return const OpenAiCredentialState(0, null);
    if (encoded is! Map<String, Object?> ||
        encoded['revision'] is! int ||
        (encoded['revision']! as int) <= 0) {
      throw const FormatException('Credential store entry is invalid.');
    }
    return OpenAiCredentialState(
      encoded['revision']! as int,
      encoded['credential'] == null
          ? null
          : OpenAiChatGptCredential.fromJson(encoded['credential']),
    );
  }

  Future<void> _write(Map<String, Object?> document) async {
    await file.parent.create(recursive: true);
    final File temporary = File('${file.path}.tmp.$pid');
    try {
      await temporary.writeAsString(jsonEncode(document), flush: true);
      if (!Platform.isWindows) {
        final ProcessResult chmod = await Process.run('chmod', <String>[
          '600',
          temporary.path,
        ]);
        if (chmod.exitCode != 0) {
          throw FileSystemException(
            'Could not restrict credential file permissions.',
            temporary.path,
          );
        }
      }
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

abstract interface class OpenAiBrowserLauncher {
  Future<void> open(Uri uri);
}

final class DesktopOpenAiBrowserLauncher implements OpenAiBrowserLauncher {
  const DesktopOpenAiBrowserLauncher();

  @override
  Future<void> open(Uri uri) async {
    final (String, List<String>) command = switch (Platform.operatingSystem) {
      'macos' => ('open', <String>[uri.toString()]),
      'windows' => ('cmd', <String>['/c', 'start', '', uri.toString()]),
      _ => ('xdg-open', <String>[uri.toString()]),
    };
    await Process.start(
      command.$1,
      command.$2,
      mode: ProcessStartMode.detached,
    );
  }
}

final class OpenAiOAuthConfiguration {
  OpenAiOAuthConfiguration({
    required this.clientId,
    required this.redirectUri,
    Uri? issuer,
    this.scopes = const <String>[
      'openid',
      'profile',
      'email',
      'offline_access',
    ],
    this.authorizationParameters = const <String, String>{},
  }) : issuer = issuer ?? Uri.parse('https://auth.openai.com') {
    _requiredHeaderText(clientId, 'clientId');
    if (!this.issuer.isAbsolute ||
        (this.issuer.scheme != 'https' &&
            !(this.issuer.scheme == 'http' &&
                _isLoopbackHost(this.issuer.host)))) {
      throw ArgumentError.value(
        this.issuer,
        'issuer',
        'Must be HTTPS or loopback HTTP.',
      );
    }
    if (redirectUri.scheme != 'http' || !_isLoopbackHost(redirectUri.host)) {
      throw ArgumentError.value(
        redirectUri,
        'redirectUri',
        'Must be an HTTP loopback URI.',
      );
    }
    if (redirectUri.path.isEmpty) {
      throw ArgumentError.value(
        redirectUri,
        'redirectUri',
        'Path is required.',
      );
    }
    if (scopes.isEmpty || scopes.any((String scope) => scope.trim().isEmpty)) {
      throw ArgumentError.value(scopes, 'scopes');
    }
    const Set<String> reserved = <String>{
      'response_type',
      'client_id',
      'redirect_uri',
      'scope',
      'code_challenge',
      'code_challenge_method',
      'state',
    };
    if (authorizationParameters.keys.any(reserved.contains) ||
        authorizationParameters.entries.any(
          (MapEntry<String, String> entry) =>
              entry.key.trim().isEmpty || entry.value.trim().isEmpty,
        )) {
      throw ArgumentError.value(
        authorizationParameters,
        'authorizationParameters',
      );
    }
  }

  final String clientId;
  final Uri issuer;
  final Uri redirectUri;
  final List<String> scopes;
  final Map<String, String> authorizationParameters;

  Uri get authorizationEndpoint => issuer.resolve('/oauth/authorize');
  Uri get tokenEndpoint => issuer.resolve('/oauth/token');
}

final class OpenAiOAuthAttempt {
  const OpenAiOAuthAttempt._({
    required this.authorizationUri,
    required this.state,
    required this.verifier,
  });

  final Uri authorizationUri;
  final String state;
  final String verifier;
}

final class OpenAiOAuthClient {
  OpenAiOAuthClient({
    required this.configuration,
    HttpClient? httpClient,
    Random? random,
    DateTime Function()? clock,
  }) : _httpClient = httpClient ?? HttpClient(),
       _ownsHttpClient = httpClient == null,
       _random = random ?? Random.secure(),
       _clock = clock ?? DateTime.now;

  final OpenAiOAuthConfiguration configuration;
  final HttpClient _httpClient;
  final bool _ownsHttpClient;
  final Random _random;
  final DateTime Function() _clock;

  OpenAiOAuthAttempt createAttempt() {
    final String verifier = _randomUrlSafe(64);
    final String state = _randomUrlSafe(32);
    final String challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    return OpenAiOAuthAttempt._(
      state: state,
      verifier: verifier,
      authorizationUri: configuration.authorizationEndpoint.replace(
        queryParameters: <String, String>{
          'response_type': 'code',
          'client_id': configuration.clientId,
          'redirect_uri': configuration.redirectUri.toString(),
          'scope': configuration.scopes.join(' '),
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
          'state': state,
          ...configuration.authorizationParameters,
        },
      ),
    );
  }

  Future<OpenAiChatGptCredential> complete(
    OpenAiOAuthAttempt attempt,
    Uri callbackUri,
  ) async {
    if (callbackUri.queryParameters['state'] != attempt.state) {
      throw const OpenAiAuthenticationException(
        'oauth_state_mismatch',
        'The OAuth callback state did not match the login attempt.',
      );
    }
    if (callbackUri.queryParameters['error'] != null) {
      throw const OpenAiAuthenticationException(
        'oauth_callback_error',
        'OpenAI rejected the browser authorization.',
      );
    }
    final String? code = callbackUri.queryParameters['code'];
    if (code == null || code.isEmpty) {
      throw const OpenAiAuthenticationException(
        'oauth_missing_code',
        'The OAuth callback did not contain an authorization code.',
      );
    }
    final Map<String, Object?> token = await _postForm(<String, String>{
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': configuration.redirectUri.toString(),
      'client_id': configuration.clientId,
      'code_verifier': attempt.verifier,
    });
    try {
      return _credentialFromInitialToken(token, _clock().toUtc());
    } on OpenAiAuthenticationException {
      rethrow;
    } on FormatException {
      throw const OpenAiAuthenticationException(
        'malformed_token_response',
        'OpenAI returned a malformed OAuth token response.',
      );
    }
  }

  Future<OpenAiChatGptCredential> refresh(
    OpenAiChatGptCredential current,
  ) async {
    final Map<String, Object?> token = await _postJson(<String, String>{
      'client_id': configuration.clientId,
      'grant_type': 'refresh_token',
      'refresh_token': current.refreshToken,
    });
    final String idToken =
        _optionalSecret(token['id_token']) ?? current.idToken;
    final _AccountClaims claims = _accountClaims(idToken);
    if (claims.accountId != current.accountId) {
      throw const OpenAiAuthenticationException(
        'account_mismatch',
        'Refreshed credentials belong to a different ChatGPT account.',
      );
    }
    return OpenAiChatGptCredential(
      idToken: idToken,
      accessToken:
          _optionalSecret(token['access_token']) ?? current.accessToken,
      refreshToken:
          _optionalSecret(token['refresh_token']) ?? current.refreshToken,
      accountId: current.accountId,
      fedRamp: claims.fedRamp,
      expiresAt:
          _expiration(token, idToken, _clock().toUtc()) ?? current.expiresAt,
    );
  }

  Future<OpenAiChatGptCredential> loginInBrowser(
    OpenAiBrowserLauncher launcher,
  ) async {
    final OpenAiOAuthAttempt attempt = createAttempt();
    final HttpServer server;
    try {
      server = await HttpServer.bind(
        configuration.redirectUri.host,
        configuration.redirectUri.port,
        shared: false,
      );
    } on Object {
      throw const OpenAiAuthenticationException(
        'oauth_callback_bind_failed',
        'The OAuth loopback callback could not be started.',
      );
    }
    try {
      await launcher.open(attempt.authorizationUri);
      await for (final HttpRequest request in server) {
        if (request.uri.path != configuration.redirectUri.path) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          continue;
        }
        try {
          final OpenAiChatGptCredential credential = await complete(
            attempt,
            request.uri,
          );
          request.response.write(
            'OpenAI login completed. You may close this window.',
          );
          await request.response.close();
          return credential;
        } on Object {
          request.response.statusCode = HttpStatus.badRequest;
          request.response.write(
            'OpenAI login failed. You may close this window.',
          );
          await request.response.close();
          rethrow;
        }
      }
      throw const OpenAiAuthenticationException(
        'oauth_callback_closed',
        'The OAuth loopback callback closed before login completed.',
      );
    } finally {
      await server.close(force: true);
    }
  }

  void close() {
    if (_ownsHttpClient) _httpClient.close();
  }

  String _randomUrlSafe(int byteCount) {
    final Uint8List bytes = Uint8List.fromList(
      List<int>.generate(byteCount, (_) => _random.nextInt(256)),
    );
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<Map<String, Object?>> _postForm(Map<String, String> body) => _post(
    body.entries
        .map(
          (MapEntry<String, String> entry) =>
              '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
        )
        .join('&'),
    ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8'),
  );

  Future<Map<String, Object?>> _postJson(Map<String, String> body) =>
      _post(jsonEncode(body), ContentType.json);

  Future<Map<String, Object?>> _post(
    String body,
    ContentType contentType,
  ) async {
    try {
      final HttpClientRequest request = await _httpClient.postUrl(
        configuration.tokenEndpoint,
      );
      request.headers.contentType = contentType;
      request.write(body);
      final HttpClientResponse response = await request.close();
      final String encoded = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const OpenAiAuthenticationException(
          'oauth_token_rejected',
          'OpenAI rejected the OAuth token request.',
        );
      }
      final Object? decoded = jsonDecode(encoded);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('Token response is not an object.');
      }
      return decoded;
    } on OpenAiAuthenticationException {
      rethrow;
    } on FormatException {
      throw const OpenAiAuthenticationException(
        'malformed_token_response',
        'OpenAI returned a malformed OAuth token response.',
      );
    } on Object {
      throw const OpenAiAuthenticationException(
        'oauth_token_transport',
        'The OpenAI OAuth token request failed.',
      );
    }
  }
}

final class OpenAiChatGptAuth {
  OpenAiChatGptAuth({
    required this.instanceId,
    required this.store,
    required this.oauth,
    DateTime Function()? clock,
    this.refreshSkew = const Duration(minutes: 5),
  }) : _clock = clock ?? DateTime.now {
    _requiredHeaderText(instanceId, 'instanceId');
  }

  final String instanceId;
  final OpenAiCredentialStore store;
  final OpenAiOAuthClient oauth;
  final DateTime Function() _clock;
  final Duration refreshSkew;
  Future<OpenAiChatGptCredential>? _refreshing;

  Future<OpenAiChatGptCredential> loginInBrowser(
    OpenAiBrowserLauncher launcher,
  ) async {
    final OpenAiCredentialState captured = await store.load(instanceId);
    final OpenAiChatGptCredential credential = await oauth.loginInBrowser(
      launcher,
    );
    final OpenAiCredentialState committed = await store.compareAndSwap(
      instanceId,
      captured.revision,
      credential,
    );
    if (!committed.committed || committed.credential == null) {
      throw const OpenAiAuthenticationException(
        'credential_changed',
        'OpenAI credentials changed while login was completing.',
      );
    }
    return committed.credential!;
  }

  Future<OpenAiChatGptCredential> install(
    OpenAiChatGptCredential credential,
  ) async {
    final OpenAiCredentialState captured = await store.load(instanceId);
    final OpenAiCredentialState committed = await store.compareAndSwap(
      instanceId,
      captured.revision,
      credential,
    );
    if (!committed.committed) {
      throw const OpenAiAuthenticationException(
        'credential_changed',
        'OpenAI credentials changed while login was completing.',
      );
    }
    return credential;
  }

  Future<OpenAiChatGptCredential> authorization() async {
    final OpenAiCredentialState state = await store.load(instanceId);
    final OpenAiChatGptCredential? credential = state.credential;
    if (credential == null) {
      throw const OpenAiAuthenticationException(
        'missing_credentials',
        'This OpenAI ChatGPT configuration is not logged in.',
      );
    }
    final DateTime? expiresAt = credential.expiresAt;
    if (expiresAt != null &&
        !expiresAt.isAfter(_clock().toUtc().add(refreshSkew))) {
      return refresh();
    }
    return credential;
  }

  Future<OpenAiChatGptCredential> refresh() {
    final Future<OpenAiChatGptCredential>? existing = _refreshing;
    if (existing != null) return existing;
    late final Future<OpenAiChatGptCredential> operation;
    operation = _performRefresh().whenComplete(() {
      if (identical(_refreshing, operation)) _refreshing = null;
    });
    _refreshing = operation;
    return operation;
  }

  Future<OpenAiChatGptCredential> _performRefresh() async {
    final OpenAiCredentialState captured = await store.load(instanceId);
    final OpenAiChatGptCredential? current = captured.credential;
    if (current == null) {
      throw const OpenAiAuthenticationException(
        'missing_credentials',
        'This OpenAI ChatGPT configuration is not logged in.',
      );
    }
    final OpenAiChatGptCredential refreshed = await oauth.refresh(current);
    final OpenAiCredentialState committed = await store.compareAndSwap(
      instanceId,
      captured.revision,
      refreshed,
    );
    if (!committed.committed || committed.credential == null) {
      throw const OpenAiAuthenticationException(
        'stale_refresh',
        'OpenAI credentials changed while refresh was in progress.',
      );
    }
    return committed.credential!;
  }

  Future<void> logout() async {
    final OpenAiCredentialState captured = await store.load(instanceId);
    final OpenAiCredentialState committed = await store.delete(
      instanceId,
      captured.revision,
    );
    if (!committed.committed || committed.credential != null) {
      throw const OpenAiAuthenticationException(
        'credential_changed',
        'OpenAI credentials changed while logout was completing.',
      );
    }
  }
}

final class OpenAiAuthenticationException implements Exception {
  const OpenAiAuthenticationException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'OpenAiAuthenticationException($code)';
}

OpenAiChatGptCredential _credentialFromInitialToken(
  Map<String, Object?> token,
  DateTime now,
) {
  final String idToken = _requiredSecret(token, 'id_token');
  final String accessToken = _requiredSecret(token, 'access_token');
  final String refreshToken = _requiredSecret(token, 'refresh_token');
  final _AccountClaims claims = _accountClaims(idToken);
  return OpenAiChatGptCredential(
    idToken: idToken,
    accessToken: accessToken,
    refreshToken: refreshToken,
    accountId: claims.accountId,
    fedRamp: claims.fedRamp,
    expiresAt: _expiration(token, idToken, now),
  );
}

_AccountClaims _accountClaims(String idToken) {
  try {
    final List<String> parts = idToken.split('.');
    if (parts.length != 3) throw const FormatException();
    final Object? decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    if (decoded is! Map<String, Object?> ||
        decoded['https://api.openai.com/auth'] is! Map<String, Object?>) {
      throw const FormatException();
    }
    final Map<String, Object?> auth =
        decoded['https://api.openai.com/auth']! as Map<String, Object?>;
    final String accountId = _requiredHeaderValue(auth, 'chatgpt_account_id');
    final Object? fedRamp = auth['chatgpt_account_is_fedramp'];
    if (fedRamp != null && fedRamp is! bool) throw const FormatException();
    return _AccountClaims(accountId, fedRamp == true);
  } on Object {
    throw const OpenAiAuthenticationException(
      'invalid_id_token',
      'The OpenAI ID token did not contain a valid ChatGPT account identity.',
    );
  }
}

DateTime? _expiration(
  Map<String, Object?> token,
  String idToken,
  DateTime now,
) {
  if (token['expires_in'] case final int seconds when seconds > 0) {
    return now.add(Duration(seconds: seconds));
  }
  try {
    final List<String> parts = idToken.split('.');
    final Object? decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    if (decoded is Map<String, Object?> && decoded['exp'] is int) {
      final int seconds = decoded['exp']! as int;
      return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    }
  } on Object {
    // Account parsing reports malformed tokens; expiry is only supplementary.
  }
  return null;
}

String _requiredSecret(Map<String, Object?> map, String key) {
  final String? value = _optionalSecret(map[key]);
  if (value == null) throw FormatException('Missing required $key.');
  return value;
}

String? _optionalSecret(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

String _requiredHeaderValue(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is! String || value.isEmpty || value != value.trim()) {
    throw FormatException('Missing or invalid $key.');
  }
  if (value.contains('\r') || value.contains('\n')) {
    throw FormatException('Invalid $key.');
  }
  return value;
}

void _requiredHeaderText(String value, String name) {
  if (value.isEmpty ||
      value != value.trim() ||
      value.contains('\r') ||
      value.contains('\n')) {
    throw ArgumentError.value(value, name);
  }
}

bool _isLoopbackHost(String host) {
  if (host.toLowerCase() == 'localhost') return true;
  return InternetAddress.tryParse(host)?.isLoopback ?? false;
}

final class _AccountClaims {
  const _AccountClaims(this.accountId, this.fedRamp);

  final String accountId;
  final bool fedRamp;
}
