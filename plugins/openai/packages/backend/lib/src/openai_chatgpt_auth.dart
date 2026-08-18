import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:oauth2/oauth2.dart' as oauth2;
import 'package:win32/win32.dart';

/// Source-visible Codex public-client identity used by current third-party
/// harnesses. This is an experimental interoperability default, not an ADELE
/// OAuth registration or a stable OpenAI third-party contract.
const String openAiExperimentalCodexOAuthClientId =
    'app_EMoamEEZ73f0CkXaXp7hrann';
const int _maximumOAuthRefreshResponseBytes = 64 * 1024;
const String openAiDefaultChatGptInstanceId = 'development-chatgpt';
const String openAiExperimentalCodexClientEnvironment =
    'ADELE_OPENAI_CHATGPT_EXPERIMENTAL_CODEX_CLIENT';

const Map<String, String> openAiChatGptAuthorizationParameters =
    <String, String>{
      'id_token_add_organizations': 'true',
      'codex_cli_simplified_flow': 'true',
      'originator': 'adele',
    };

String openAiChatGptInstanceId(Map<String, String> environment) =>
    _nonBlankEnvironment(environment, 'ADELE_OPENAI_CHATGPT_INSTANCE_ID') ??
    openAiDefaultChatGptInstanceId;

OpenAiOAuthClientIdentity openAiOAuthClientIdentity(
  Map<String, String> environment, {
  required bool allowDevelopmentFallback,
}) {
  final String? configured = _nonBlankEnvironment(
    environment,
    'ADELE_OPENAI_CHATGPT_CLIENT_ID',
  );
  if (configured != null) return OpenAiOAuthClientIdentity(configured, false);
  final bool optedIn =
      environment[openAiExperimentalCodexClientEnvironment] == '1';
  if (!allowDevelopmentFallback && !optedIn) {
    throw StateError(
      'The experimental ChatGPT configuration requires '
      'ADELE_OPENAI_CHATGPT_CLIENT_ID or explicit '
      '$openAiExperimentalCodexClientEnvironment=1 opt-in.',
    );
  }
  return const OpenAiOAuthClientIdentity(
    openAiExperimentalCodexOAuthClientId,
    true,
  );
}

final class OpenAiOAuthClientIdentity {
  const OpenAiOAuthClientIdentity(this.clientId, this.experimentalCodexClient);

  final String clientId;
  final bool experimentalCodexClient;
}

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
    final OpenAiCredentialState current =
        _states[instanceId] ?? const OpenAiCredentialState(0, null);
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
    final OpenAiCredentialState current =
        _states[instanceId] ?? const OpenAiCredentialState(0, null);
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
  static final Map<String, Future<void>> _mutationTails =
      <String, Future<void>>{};

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
  ) {
    final Completer<OpenAiCredentialState> result =
        Completer<OpenAiCredentialState>();
    final String path = file.absolute.path;
    final Future<void> previous = _mutationTails[path] ?? Future<void>.value();
    late final Future<void> next;
    next = previous
        .then((_) async {
          try {
            result.complete(
              await _performMutation(instanceId, expectedRevision, credential),
            );
          } on Object catch (error, stackTrace) {
            result.completeError(error, stackTrace);
          }
        })
        .whenComplete(() {
          if (identical(_mutationTails[path], next)) {
            _mutationTails.remove(path);
          }
        });
    _mutationTails[path] = next;
    return result.future;
  }

  Future<OpenAiCredentialState> _performMutation(
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
    final Directory temporaryDirectory = await file.parent.createTemp(
      '${file.uri.pathSegments.last}.tmp.$pid.',
    );
    final File temporary = File('${temporaryDirectory.path}/credential-store');
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
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    }
  }
}

abstract interface class OpenAiBrowserLauncher {
  Future<void> open(Uri uri);
}

typedef OpenAiBrowserProcessStarter =
    Future<void> Function(String executable, List<String> arguments);
typedef OpenAiWindowsUrlOpener = Future<void> Function(Uri uri);

final class DesktopOpenAiBrowserLauncher implements OpenAiBrowserLauncher {
  const DesktopOpenAiBrowserLauncher({
    String? operatingSystem,
    OpenAiBrowserProcessStarter? processStarter,
    OpenAiWindowsUrlOpener? windowsUrlOpener,
  }) : _operatingSystem = operatingSystem,
       _processStarter = processStarter,
       _windowsUrlOpener = windowsUrlOpener;

  final String? _operatingSystem;
  final OpenAiBrowserProcessStarter? _processStarter;
  final OpenAiWindowsUrlOpener? _windowsUrlOpener;

  @override
  Future<void> open(Uri uri) async {
    final String operatingSystem = _operatingSystem ?? Platform.operatingSystem;
    if (operatingSystem == 'windows') {
      await (_windowsUrlOpener ?? _openWithWindowsShell)(uri);
      return;
    }
    final (String, List<String>) command = switch (operatingSystem) {
      'macos' => ('open', <String>[uri.toString()]),
      _ => ('xdg-open', <String>[uri.toString()]),
    };
    await (_processStarter ?? _startDetached)(command.$1, command.$2);
  }
}

Future<void> _startDetached(String executable, List<String> arguments) async {
  await Process.start(executable, arguments, mode: ProcessStartMode.detached);
}

Future<void> _openWithWindowsShell(Uri uri) async {
  final HRESULT comResult = CoInitializeEx(COINIT_APARTMENTTHREADED);
  if (comResult.isError && comResult != RPC_E_CHANGED_MODE) {
    throw WindowsException(comResult);
  }
  final bool uninitializeCom = comResult.isOk;
  final PWSTR encodedUri = uri.toString().toPwstr(allocator: calloc);
  final Pointer<SHELLEXECUTEINFO> info = calloc<SHELLEXECUTEINFO>();
  try {
    info.ref
      ..cbSize = sizeOf<SHELLEXECUTEINFO>()
      // Dart console isolates have no Windows message loop.
      ..fMask =
          0x00000100 // SEE_MASK_NOASYNC
      ..lpFile = encodedUri
      ..nShow = SW_SHOWNORMAL;
    final Win32Result<bool> result = ShellExecuteEx(info);
    if (!result.value) {
      throw WindowsException(result.error.toHRESULT());
    }
  } finally {
    calloc.free(info);
    calloc.free(encodedUri);
    if (uninitializeCom) CoUninitialize();
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
    if (redirectUri.port == 0) {
      throw ArgumentError.value(
        redirectUri,
        'redirectUri',
        'Must use a fixed nonzero callback port.',
      );
    }
    if (redirectUri.hasFragment) {
      throw ArgumentError.value(
        redirectUri,
        'redirectUri',
        'Must not include a fragment.',
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
  OpenAiOAuthAttempt._({
    required this.authorizationUri,
    required this.state,
    required oauth2.AuthorizationCodeGrant grant,
  }) : _grant = grant;

  final Uri authorizationUri;
  final String state;
  final oauth2.AuthorizationCodeGrant _grant;

  bool acceptsState(Uri callbackUri) =>
      callbackUri.queryParameters['state'] == state;

  void close() => _grant.close();
}

final class OpenAiChatGptAuthorization {
  const OpenAiChatGptAuthorization(this.revision, this.credential);

  final int revision;
  final OpenAiChatGptCredential credential;
}

final class OpenAiOAuthClient {
  OpenAiOAuthClient({
    required this.configuration,
    HttpClient? refreshHttpClient,
    Random? random,
    DateTime Function()? clock,
  }) : _refreshHttpClient = refreshHttpClient ?? HttpClient(),
       _ownsRefreshHttpClient = refreshHttpClient == null,
       _random = random ?? Random.secure(),
       _clock = clock ?? DateTime.now;

  final OpenAiOAuthConfiguration configuration;
  final HttpClient _refreshHttpClient;
  final bool _ownsRefreshHttpClient;
  final Random _random;
  final DateTime Function() _clock;

  OpenAiOAuthAttempt createAttempt() {
    final String state = _randomUrlSafe(32);
    final Uri authorizationEndpoint = configuration.authorizationEndpoint
        .replace(
          queryParameters: <String, String>{
            ...configuration.authorizationEndpoint.queryParameters,
            ...configuration.authorizationParameters,
          },
        );
    final oauth2.AuthorizationCodeGrant grant = oauth2.AuthorizationCodeGrant(
      configuration.clientId,
      authorizationEndpoint,
      configuration.tokenEndpoint,
      basicAuth: false,
    );
    return OpenAiOAuthAttempt._(
      state: state,
      grant: grant,
      authorizationUri: grant.getAuthorizationUrl(
        configuration.redirectUri,
        scopes: configuration.scopes,
        state: state,
      ),
    );
  }

  Future<OpenAiChatGptCredential> complete(
    OpenAiOAuthAttempt attempt,
    Uri callbackUri,
  ) async {
    oauth2.Client? authorizedClient;
    try {
      authorizedClient = await attempt._grant.handleAuthorizationResponse(
        callbackUri.queryParameters,
      );
      return _credentialFromInitialOAuth(authorizedClient.credentials);
    } on oauth2.AuthorizationException {
      final bool callbackError = callbackUri.queryParameters['error'] != null;
      throw OpenAiAuthenticationException(
        callbackError ? 'oauth_callback_error' : 'oauth_token_rejected',
        callbackError
            ? 'OpenAI rejected the browser authorization.'
            : 'OpenAI rejected the OAuth token request.',
      );
    } on FormatException {
      if (!attempt.acceptsState(callbackUri)) {
        throw const OpenAiAuthenticationException(
          'oauth_state_mismatch',
          'The OAuth callback state did not match the login attempt.',
        );
      }
      if (callbackUri.queryParameters['code'] == null &&
          callbackUri.queryParameters['error'] == null) {
        throw const OpenAiAuthenticationException(
          'oauth_missing_code',
          'The OAuth callback did not contain an authorization code.',
        );
      }
      throw const OpenAiAuthenticationException(
        'malformed_token_response',
        'OpenAI returned a malformed OAuth token response.',
        failureKind: OpenAiAuthenticationFailureKind.malformedResponse,
      );
    } on OpenAiAuthenticationException {
      rethrow;
    } on Object {
      throw const OpenAiAuthenticationException(
        'oauth_token_transport',
        'The OpenAI OAuth token request failed.',
        failureKind: OpenAiAuthenticationFailureKind.transport,
      );
    } finally {
      authorizedClient?.close();
      attempt.close();
    }
  }

  Future<OpenAiChatGptCredential> refresh(
    OpenAiChatGptCredential current,
  ) async {
    final Map<String, Object?> token = await _postRefreshJson(<String, String>{
      'client_id': configuration.clientId,
      'grant_type': 'refresh_token',
      'refresh_token': current.refreshToken,
    });
    try {
      final String accessToken = _requiredTokenSecret(token, 'access_token');
      final String? newIdToken = _optionalTokenSecret(token, 'id_token');
      final String idToken = newIdToken ?? current.idToken;
      final _AccountClaims claims = _accountClaims(idToken);
      if (claims.accountId != current.accountId) {
        throw const OpenAiAuthenticationException(
          'account_mismatch',
          'Refreshed credentials belong to a different ChatGPT account.',
        );
      }
      return OpenAiChatGptCredential(
        idToken: idToken,
        accessToken: accessToken,
        refreshToken:
            _optionalTokenSecret(token, 'refresh_token') ??
            current.refreshToken,
        accountId: current.accountId,
        fedRamp: claims.fedRamp,
        expiresAt: _refreshExpiration(token, newIdToken, _clock().toUtc()),
      );
    } on OpenAiAuthenticationException {
      rethrow;
    } on FormatException {
      throw const OpenAiAuthenticationException(
        'oauth_refresh_malformed_response',
        'OpenAI returned a malformed OAuth refresh response.',
        failureKind: OpenAiAuthenticationFailureKind.malformedResponse,
      );
    }
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
      attempt.close();
      throw const OpenAiAuthenticationException(
        'oauth_callback_bind_failed',
        'The OAuth loopback callback could not be started.',
        failureKind: OpenAiAuthenticationFailureKind.transport,
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
        // AuthorizationCodeGrant is single-use even after invalid state. Gate
        // stray requests so the library can validate the legitimate callback.
        if (!attempt.acceptsState(request.uri)) {
          request.response.statusCode = HttpStatus.badRequest;
          request.response.write('OpenAI login callback was invalid.');
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
      attempt.close();
      await server.close(force: true);
    }
  }

  void close() {
    if (_ownsRefreshHttpClient) _refreshHttpClient.close();
  }

  String _randomUrlSafe(int byteCount) {
    final Uint8List bytes = Uint8List.fromList(
      List<int>.generate(byteCount, (_) => _random.nextInt(256)),
    );
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Current Codex refresh is JSON rather than the standard form encoding used
  /// by package:oauth2. Durable publication remains owned by ADELE's CAS store.
  Future<Map<String, Object?>> _postRefreshJson(
    Map<String, String> body,
  ) async {
    final HttpClientResponse response;
    try {
      final HttpClientRequest request = await _refreshHttpClient.postUrl(
        configuration.tokenEndpoint,
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      response = await request.close();
    } on SocketException {
      throw const OpenAiAuthenticationException(
        'oauth_refresh_transport',
        'The OpenAI OAuth refresh service could not be reached.',
        failureKind: OpenAiAuthenticationFailureKind.transport,
      );
    } on HandshakeException {
      throw const OpenAiAuthenticationException(
        'oauth_refresh_transport',
        'The OpenAI OAuth refresh TLS connection failed.',
        failureKind: OpenAiAuthenticationFailureKind.transport,
      );
    } on HttpException {
      throw const OpenAiAuthenticationException(
        'oauth_refresh_transport',
        'The OpenAI OAuth refresh HTTP operation failed.',
        failureKind: OpenAiAuthenticationFailureKind.transport,
      );
    }

    final _BoundedOAuthResponse captured;
    try {
      captured = await _readBoundedOAuthResponse(response);
    } on SocketException {
      throw const OpenAiAuthenticationException(
        'oauth_refresh_transport',
        'The OpenAI OAuth refresh response could not be read.',
        failureKind: OpenAiAuthenticationFailureKind.transport,
      );
    } on HttpException {
      throw const OpenAiAuthenticationException(
        'oauth_refresh_transport',
        'The OpenAI OAuth refresh response could not be read.',
        failureKind: OpenAiAuthenticationFailureKind.transport,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final String? providerErrorCode = captured.exceededLimit
          ? null
          : _oauthErrorCode(utf8.decode(captured.bytes, allowMalformed: true));
      final Map<String, Object?> details = <String, Object?>{
        'httpStatus': response.statusCode,
        if (captured.exceededLimit) 'responseBodyTooLarge': true,
        if (_safeRetryAfter(response.headers) case final String retryAfter)
          'retryAfter': retryAfter,
        'oauthErrorCode': ?providerErrorCode,
      };
      if (response.statusCode == HttpStatus.unauthorized ||
          _permanentRefreshErrors.contains(providerErrorCode)) {
        throw OpenAiAuthenticationException(
          'oauth_refresh_rejected',
          'OpenAI rejected the stored OAuth refresh credential.',
          safeDetails: details,
        );
      }
      if (response.statusCode == HttpStatus.tooManyRequests) {
        throw OpenAiAuthenticationException(
          'oauth_refresh_rate_limited',
          'The OpenAI OAuth refresh service rate limited the request.',
          failureKind: OpenAiAuthenticationFailureKind.rateLimited,
          safeDetails: details,
        );
      }
      throw OpenAiAuthenticationException(
        'oauth_refresh_unavailable',
        'The OpenAI OAuth refresh service is temporarily unavailable.',
        failureKind: OpenAiAuthenticationFailureKind.unavailable,
        safeDetails: details,
      );
    }

    if (captured.exceededLimit) {
      throw const OpenAiAuthenticationException(
        'oauth_refresh_response_too_large',
        'OpenAI returned an oversized OAuth refresh response.',
        failureKind: OpenAiAuthenticationFailureKind.malformedResponse,
        safeDetails: <String, Object?>{'responseBodyTooLarge': true},
      );
    }
    try {
      final String encoded = utf8.decode(captured.bytes);
      final Object? decoded = jsonDecode(encoded);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('Token response is not an object.');
      }
      if (decoded.containsKey('error')) {
        throw const FormatException(
          'Successful refresh response contained an error.',
        );
      }
      _requiredTokenSecret(decoded, 'access_token');
      return decoded;
    } on FormatException {
      throw const OpenAiAuthenticationException(
        'oauth_refresh_malformed_response',
        'OpenAI returned a malformed OAuth refresh response.',
        failureKind: OpenAiAuthenticationFailureKind.malformedResponse,
      );
    }
  }
}

final class _BoundedOAuthResponse {
  const _BoundedOAuthResponse(this.bytes, this.exceededLimit);

  final Uint8List bytes;
  final bool exceededLimit;
}

Future<_BoundedOAuthResponse> _readBoundedOAuthResponse(
  HttpClientResponse response,
) async {
  final BytesBuilder bytes = BytesBuilder(copy: false);
  final StreamIterator<List<int>> iterator = StreamIterator<List<int>>(
    response,
  );
  try {
    while (await iterator.moveNext()) {
      final List<int> chunk = iterator.current;
      final int remaining = _maximumOAuthRefreshResponseBytes - bytes.length;
      if (chunk.length >= remaining) {
        bytes.add(chunk.sublist(0, remaining));
        await iterator.cancel();
        return _BoundedOAuthResponse(bytes.takeBytes(), true);
      }
      bytes.add(chunk);
    }
    return _BoundedOAuthResponse(bytes.takeBytes(), false);
  } on Object {
    await iterator.cancel();
    rethrow;
  }
}

Future<OpenAiCredentialState> _loadCredentialState(
  OpenAiCredentialStore store,
  String instanceId,
) => _credentialStoreOperation(() => store.load(instanceId));

Future<T> _credentialStoreOperation<T>(Future<T> Function() operation) async {
  try {
    return await operation();
  } on FormatException {
    throw const OpenAiAuthenticationException(
      'credential_store_corrupt',
      'The stored ChatGPT login state is corrupt and must be replaced.',
    );
  } on FileSystemException {
    throw const OpenAiAuthenticationException(
      'credential_store_io',
      'The stored ChatGPT login state could not be accessed.',
      failureKind: OpenAiAuthenticationFailureKind.transport,
    );
  } on ProcessException {
    throw const OpenAiAuthenticationException(
      'credential_store_io',
      'The stored ChatGPT login state could not be accessed.',
      failureKind: OpenAiAuthenticationFailureKind.transport,
    );
  }
}

Future<void> logoutOpenAiChatGptInstance({
  required String instanceId,
  required OpenAiCredentialStore store,
}) async {
  _requiredHeaderText(instanceId, 'instanceId');
  final OpenAiCredentialState captured = await _loadCredentialState(
    store,
    instanceId,
  );
  final OpenAiCredentialState committed = await _credentialStoreOperation(
    () => store.delete(instanceId, captured.revision),
  );
  if (!committed.committed || committed.credential != null) {
    throw const OpenAiAuthenticationException(
      'credential_changed',
      'OpenAI credentials changed while logout was completing.',
    );
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
  Future<OpenAiCredentialState>? _refreshing;
  int? _refreshingRevision;

  Future<OpenAiChatGptCredential> loginInBrowser(
    OpenAiBrowserLauncher launcher,
  ) async {
    final OpenAiCredentialState captured = await _loadCredentialState(
      store,
      instanceId,
    );
    final OpenAiChatGptCredential credential = await oauth.loginInBrowser(
      launcher,
    );
    final OpenAiCredentialState committed = await _credentialStoreOperation(
      () => store.compareAndSwap(instanceId, captured.revision, credential),
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
    final OpenAiCredentialState captured = await _loadCredentialState(
      store,
      instanceId,
    );
    final OpenAiCredentialState committed = await _credentialStoreOperation(
      () => store.compareAndSwap(instanceId, captured.revision, credential),
    );
    if (!committed.committed) {
      throw const OpenAiAuthenticationException(
        'credential_changed',
        'OpenAI credentials changed while login was completing.',
      );
    }
    return credential;
  }

  Future<OpenAiChatGptAuthorization> authorization() async {
    final OpenAiCredentialState state = await _loadCredentialState(
      store,
      instanceId,
    );
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
      final OpenAiCredentialState refreshed = await _refresh(
        expectedRevision: state.revision,
      );
      return OpenAiChatGptAuthorization(
        refreshed.revision,
        refreshed.credential!,
      );
    }
    return OpenAiChatGptAuthorization(state.revision, credential);
  }

  Future<OpenAiChatGptCredential> refresh() async {
    final OpenAiCredentialState current = await _loadCredentialState(
      store,
      instanceId,
    );
    if (current.credential == null) {
      throw const OpenAiAuthenticationException(
        'missing_credentials',
        'This OpenAI ChatGPT configuration is not logged in.',
      );
    }
    return (await _refresh(expectedRevision: current.revision)).credential!;
  }

  Future<OpenAiChatGptAuthorization> recoverUnauthorized(
    int rejectedRevision,
  ) async {
    final OpenAiCredentialState current = await _loadCredentialState(
      store,
      instanceId,
    );
    final OpenAiChatGptCredential? credential = current.credential;
    if (credential == null) {
      throw const OpenAiAuthenticationException(
        'missing_credentials',
        'This OpenAI ChatGPT configuration is not logged in.',
      );
    }
    if (current.revision != rejectedRevision) {
      return OpenAiChatGptAuthorization(current.revision, credential);
    }
    final OpenAiCredentialState refreshed = await _refresh(
      expectedRevision: rejectedRevision,
    );
    return OpenAiChatGptAuthorization(
      refreshed.revision,
      refreshed.credential!,
    );
  }

  Future<OpenAiCredentialState> _refresh({required int expectedRevision}) {
    final Future<OpenAiCredentialState>? existing = _refreshing;
    if (existing != null) {
      if (_refreshingRevision == expectedRevision) return existing;
      return existing.then(
        (_) => _refresh(expectedRevision: expectedRevision),
        onError: (_) => _refresh(expectedRevision: expectedRevision),
      );
    }
    late final Future<OpenAiCredentialState> operation;
    operation = _performRefresh(expectedRevision: expectedRevision)
        .whenComplete(() {
          if (identical(_refreshing, operation)) {
            _refreshing = null;
            _refreshingRevision = null;
          }
        });
    _refreshing = operation;
    _refreshingRevision = expectedRevision;
    return operation;
  }

  Future<OpenAiCredentialState> _performRefresh({
    required int expectedRevision,
  }) async {
    final OpenAiCredentialState captured = await _loadCredentialState(
      store,
      instanceId,
    );
    final OpenAiChatGptCredential? current = captured.credential;
    if (current == null) {
      throw const OpenAiAuthenticationException(
        'missing_credentials',
        'This OpenAI ChatGPT configuration is not logged in.',
      );
    }
    if (captured.revision != expectedRevision) {
      return captured;
    }
    final OpenAiChatGptCredential refreshed = await oauth.refresh(current);
    final OpenAiCredentialState committed = await _credentialStoreOperation(
      () => store.compareAndSwap(instanceId, captured.revision, refreshed),
    );
    if (!committed.committed || committed.credential == null) {
      throw const OpenAiAuthenticationException(
        'stale_refresh',
        'OpenAI credentials changed while refresh was in progress.',
      );
    }
    return committed;
  }

  Future<void> logout() =>
      logoutOpenAiChatGptInstance(instanceId: instanceId, store: store);
}

enum OpenAiAuthenticationFailureKind {
  authentication,
  rateLimited,
  unavailable,
  transport,
  malformedResponse,
}

final class OpenAiAuthenticationException implements Exception {
  const OpenAiAuthenticationException(
    this.code,
    this.message, {
    this.failureKind = OpenAiAuthenticationFailureKind.authentication,
    this.safeDetails = const <String, Object?>{},
  });

  final String code;
  final String message;
  final OpenAiAuthenticationFailureKind failureKind;
  final Map<String, Object?> safeDetails;

  @override
  String toString() => 'OpenAiAuthenticationException($code)';
}

OpenAiChatGptCredential _credentialFromInitialOAuth(
  oauth2.Credentials credential,
) {
  final String idToken = _requiredOAuthSecret(credential.idToken, 'id_token');
  final String accessToken = _requiredOAuthSecret(
    credential.accessToken,
    'access_token',
  );
  final String refreshToken = _requiredOAuthSecret(
    credential.refreshToken,
    'refresh_token',
  );
  final _AccountClaims claims = _accountClaims(idToken);
  return OpenAiChatGptCredential(
    idToken: idToken,
    accessToken: accessToken,
    refreshToken: refreshToken,
    accountId: claims.accountId,
    fedRamp: claims.fedRamp,
    expiresAt: credential.expiration ?? _idTokenExpiration(idToken),
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

DateTime? _refreshExpiration(
  Map<String, Object?> token,
  String? newIdToken,
  DateTime now,
) {
  if (token.containsKey('expires_in')) {
    if (token['expires_in'] case final int seconds when seconds > 0) {
      return now.add(Duration(seconds: seconds));
    }
    throw const FormatException('Invalid expires_in.');
  }
  return newIdToken == null ? null : _idTokenExpiration(newIdToken);
}

DateTime? _idTokenExpiration(String idToken) {
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

String _requiredOAuthSecret(String? value, String name) {
  if (value == null || value.isEmpty) {
    throw FormatException('Missing required $name.');
  }
  return value;
}

String? _optionalSecret(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

String? _optionalTokenSecret(Map<String, Object?> token, String name) {
  if (!token.containsKey(name)) return null;
  final String? value = _optionalSecret(token[name]);
  if (value == null ||
      value != value.trim() ||
      value.contains('\r') ||
      value.contains('\n')) {
    throw FormatException('Invalid $name.');
  }
  return value;
}

String _requiredTokenSecret(Map<String, Object?> token, String name) {
  final String? value = _optionalTokenSecret(token, name);
  if (value == null) throw FormatException('Missing required $name.');
  return value;
}

const Set<String> _permanentRefreshErrors = <String>{
  'invalid_grant',
  'refresh_token_expired',
  'refresh_token_reused',
  'refresh_token_invalidated',
};

const Set<String> _safeOAuthErrorCodes = <String>{
  ..._permanentRefreshErrors,
  'rate_limit',
  'rate_limit_exceeded',
  'server_error',
  'temporarily_unavailable',
};

String? _oauthErrorCode(String encoded) {
  try {
    final Object? decoded = jsonDecode(encoded);
    if (decoded is! Map<String, Object?>) return null;
    final Object? error = decoded['error'];
    final Object? candidate = switch (error) {
      final Map<String, Object?> value => value['code'],
      final String value => value,
      _ => decoded['code'],
    };
    if (candidate is! String) return null;
    final String normalized = candidate.toLowerCase();
    return _safeOAuthErrorCodes.contains(normalized) ? normalized : null;
  } on FormatException {
    return null;
  }
}

String? _safeRetryAfter(HttpHeaders headers) {
  final List<String>? values = headers[HttpHeaders.retryAfterHeader];
  if (values == null || values.length != 1) return null;
  final String value = values.single.trim();
  if (RegExp(r'^\d{1,10}$').hasMatch(value)) return value;
  if (value.length > 64) return null;
  try {
    HttpDate.parse(value);
    return value;
  } on HttpException {
    return null;
  }
}

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

String? _nonBlankEnvironment(Map<String, String> environment, String name) {
  final String? value = environment[name];
  return value == null || value.trim().isEmpty ? null : value;
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
