import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:openai_contract/openai_contract.dart'
    show openAiResponsesItemKind, openAiResponsesItemVersion;

import 'src/openai_chatgpt_auth.dart';
import 'src/openai_endpoint.dart';
import 'src/openai_native_presentation.dart';

export 'src/openai_configured_provider.dart';

// Plugin-owned runtime identities, temporarily mirrored by stock app bootstrap.
// Future discovery/activation metadata should replace that hard-coded app knowledge.
const String openAiPluginId = 'dev.adele.openai';
const String openAiApiKeyProviderId = 'dev.adele.openai.api-key';
const String openAiChatGptProviderId = 'dev.adele.openai.chatgpt-experimental';
const String openAiChatGptConfigurationContext = 'chatgpt-experimental';
const String _semanticMetadataKind = 'openai.responses.semantic-item.v1';
const int _maximumErrorBodyBytes = 16 * 1024;

// Exact maintained IDs with summary support in OpenAI's reasoning guide and
// first-party Codex catalog; unknown models retain the previous request policy.
// https://developers.openai.com/api/docs/guides/reasoning#reasoning-summaries
// https://github.com/openai/codex/blob/7f01a84effccef40d4726c3ca12e6c839ec98d7a/codex-rs/models-manager/models.json
const Set<String> _reasoningSummaryModels = <String>{
  'gpt-6-astra',
  'gpt-5.6-sol',
  'gpt-5.6-terra',
  'gpt-5.6-luna',
  'gpt-5.5',
  'gpt-5.4',
};

final class OpenAiModelProvider implements ModelProviderService {
  OpenAiModelProvider({
    required String apiKey,
    Uri? endpoint,
    HttpClient? httpClient,
    this.responseOpenTimeout = const Duration(seconds: 30),
    this.inactivityTimeout = const Duration(minutes: 5),
    this.transportRetryDelay = const Duration(milliseconds: 200),
    this.cleanupTimeout = const Duration(seconds: 1),
  }) : _apiKey = _validateApiKey(apiKey),
       _chatGptAuth = null,
       _profile = _OpenAiRequestProfile.apiKey,
       _endpoint = validateOpenAiEndpoint(
         endpoint ?? Uri.parse('https://api.openai.com/v1/responses'),
       ),
       _httpClient = httpClient ?? HttpClient(),
       _ownsHttpClient = httpClient == null;

  OpenAiModelProvider.chatGpt({
    required OpenAiChatGptAuth auth,
    Uri? endpoint,
    HttpClient? httpClient,
    this.responseOpenTimeout = const Duration(seconds: 30),
    this.inactivityTimeout = const Duration(minutes: 5),
    this.transportRetryDelay = const Duration(milliseconds: 200),
    this.cleanupTimeout = const Duration(seconds: 1),
  }) : _apiKey = null,
       _chatGptAuth = auth,
       _profile = _OpenAiRequestProfile.chatGpt,
       _endpoint = validateOpenAiEndpoint(
         endpoint ??
             Uri.parse('https://chatgpt.com/backend-api/codex/responses'),
       ),
       _httpClient = httpClient ?? HttpClient(),
       _ownsHttpClient = httpClient == null;

  final String? _apiKey;
  final OpenAiChatGptAuth? _chatGptAuth;
  final _OpenAiRequestProfile _profile;
  final Uri _endpoint;
  final HttpClient _httpClient;
  final bool _ownsHttpClient;
  final Duration responseOpenTimeout;
  final Duration inactivityTimeout;
  final Duration transportRetryDelay;
  final Duration cleanupTimeout;
  final Set<Future<void> Function()> _invocations = {};
  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    for (final cancel in _invocations.toList()) {
      unawaited(cancel());
    }
    if (_ownsHttpClient) _httpClient.close();
  }

  @override
  Stream<ModelProviderEvent> invoke(ModelProviderRequest request) {
    late StreamController<ModelProviderEvent> controller;
    _OpenAiHttpAttempt? attempt;
    bool cancelled = false;
    bool settled = false;
    bool published = false;
    int httpAttempts = 0;
    int transportRetries = 0;
    Timer? retryTimer;
    Completer<void>? retryWait;
    _ChatGptAffinity? affinity;
    final List<String> affinitySecrets = <String>[
      ?_apiKey,
      _endpoint.toString(),
      if (_endpoint.hasQuery) _endpoint.query,
    ];

    Future<void> cancel() async {
      cancelled = true;
      retryTimer?.cancel();
      if (retryWait case final wait? when !wait.isCompleted) wait.complete();
      _invocations.remove(cancel);
      unawaited(controller.close());
      await attempt?.stop();
    }

    void emitTerminal(ModelProviderTerminal terminal) {
      if (cancelled || settled) return;
      settled = true;
      final ModelProviderFailure? failure = terminal.failure;
      controller.add(
        _terminalEvent(
          ModelProviderTerminal(
            settlement: terminal.settlement,
            incompleteReason: terminal.incompleteReason,
            failure: failure == null
                ? null
                : ModelProviderFailure(
                    kind: failure.kind,
                    providerCode: _redactProviderText(
                      failure.providerCode,
                      affinitySecrets,
                    ),
                    providerMessage: _redactProviderText(
                      failure.providerMessage,
                      affinitySecrets,
                    ),
                    providerDetails: <String, Object?>{
                      'transportStage': attempt?.stage ?? 'authorization',
                      'cause': 'provider_terminal',
                      ...failure.providerDetails,
                      'httpAttemptCount': httpAttempts,
                      'transportRetryCount': transportRetries,
                      'outputPublished': published,
                    },
                  ),
            providerStopReason: _redactProviderText(
              terminal.providerStopReason,
              affinitySecrets,
            ),
            usage: terminal.usage,
            effectiveModel: _redactProviderText(
              terminal.effectiveModel,
              affinitySecrets,
            ),
            responseId: _redactProviderText(
              terminal.responseId,
              affinitySecrets,
            ),
            requestId: _redactProviderText(terminal.requestId, affinitySecrets),
            nativeState: null,
            affinityState: affinity?.state,
          ),
        ),
      );
      unawaited(controller.close());
    }

    void fail(
      ModelProviderFailureKind kind,
      String code,
      String message, {
      Map<String, Object?> details = const <String, Object?>{},
      String? requestId,
    }) {
      emitTerminal(
        _failedTerminal(
          kind,
          code,
          message,
          details: details,
          requestId: requestId,
        ),
      );
    }

    Future<void> start() async {
      final String body;
      try {
        try {
          affinitySecrets.addAll(
            _endpoint.queryParametersAll.values.expand((values) => values),
          );
        } on FormatException {
          throw const _OpenAiRequestException(
            ModelProviderFailureKind.invalidRequest,
            'invalid_endpoint_query',
            'The OpenAI endpoint query is not valid UTF-8.',
          );
        }
        if (_chatGptAuth != null && request.affinity != null) {
          affinity = _ChatGptAffinity(
            request.affinity!,
            model: request.model,
            instanceId: _chatGptAuth.instanceId,
            endpoint: _endpoint,
          );
          affinitySecrets.addAll(<String>[
            request.affinity!.id,
            ?affinity!.state?.data['turnState'] as String?,
            ?affinity!.state?.data['accountId'] as String?,
          ]);
        }
        body = jsonEncode(_lowerRequest(request, _profile));
      } on _OpenAiRequestException catch (error) {
        fail(
          error.kind,
          error.code,
          error.message,
          details: const {
            'transportStage': 'request_validation',
            'cause': 'invalid_request',
          },
        );
        return;
      } on Object {
        fail(
          ModelProviderFailureKind.invalidRequest,
          'invalid_request',
          'The model request could not be encoded.',
          details: const {
            'transportStage': 'request_validation',
            'cause': 'invalid_request',
          },
        );
        return;
      }
      Future<void> send(
        _OpenAiHttpAttempt current,
        OpenAiChatGptAuthorization? authorization,
      ) async {
        String? requestId;
        int? status;
        void reject(
          ModelProviderFailureKind kind,
          String code,
          String message, {
          bool retryable = false,
          Map<String, Object?> details = const {},
        }) {
          current.finish(
            _failedTerminal(
              kind,
              code,
              message,
              details: details,
              requestId: requestId,
            ),
            retryable: retryable,
          );
        }

        void transportError(Object error) {
          if (!current.active) return;
          final String cause = switch (error) {
            SocketException() => 'socket',
            HttpException() => 'http',
            HandshakeException() => 'tls',
            TimeoutException() => 'timeout',
            _ => 'unknown',
          };
          final Map<String, Object?> details = {
            'cause': cause,
            if (error is SocketException && error.osError != null)
              'osErrorCode': error.osError!.errorCode,
          };
          // Once a status is known, a broken error body must not turn that
          // nonretryable rejection into a retryable transport failure.
          if (status != null && (status < 200 || status >= 300)) {
            final failure = _classifyHttpFailure(
              status,
              '',
              requestId,
              null,
              true,
              affinitySecrets,
            );
            reject(
              failure.kind,
              failure.code,
              failure.message,
              details: {...failure.details, ...details},
            );
            return;
          }
          final String code = current.stage == 'sse'
              ? 'stream_transport'
              : switch (error) {
                  SocketException() => 'network_error',
                  HttpException() => 'http_transport',
                  HandshakeException() => 'tls_error',
                  TimeoutException() => 'response_open_timeout',
                  _ => 'transport_error',
                };
          reject(
            ModelProviderFailureKind.transport,
            code,
            current.stage == 'sse'
                ? 'The OpenAI response stream failed.'
                : switch (error) {
                    SocketException() =>
                      'The OpenAI request could not reach the provider.',
                    HandshakeException() => 'The OpenAI TLS connection failed.',
                    HttpException() => 'The OpenAI HTTP operation failed.',
                    TimeoutException() =>
                      'The OpenAI HTTP response did not open before the deadline.',
                    _ => 'The OpenAI transport failed.',
                  },
            retryable:
                error is SocketException ||
                error is HttpException ||
                error is TimeoutException,
            details: details,
          );
        }

        try {
          final OpenAiChatGptCredential? chatGptCredential =
              authorization?.credential;
          if (chatGptCredential != null) {
            affinity?.bind(chatGptCredential);
            affinitySecrets.addAll([
              chatGptCredential.accessToken,
              chatGptCredential.accountId,
            ]);
          }
          if (!current.active) return;
          current.timer = Timer(responseOpenTimeout, () {
            reject(
              ModelProviderFailureKind.transport,
              'response_open_timeout',
              'The OpenAI HTTP response did not open before the deadline.',
              retryable: true,
              details: const {'cause': 'timeout'},
            );
          });
          final HttpClientRequest outgoing = await _httpClient.postUrl(
            _endpoint,
          );
          // postUrl has no per-request cancellation handle until it completes.
          // A late acquisition is never allowed to submit headers or a body.
          if (!current.active) {
            outgoing.abort();
            return;
          }
          current.request = outgoing;
          current.stage = 'request_submission';
          // Redirects would escape both the captured endpoint and attempt budget.
          outgoing.followRedirects = false;
          outgoing.headers.contentType = ContentType.json;
          outgoing.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
          outgoing.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer ${chatGptCredential?.accessToken ?? _apiKey!}',
          );
          if (chatGptCredential != null) {
            outgoing.headers.set(
              'ChatGPT-Account-ID',
              chatGptCredential.accountId,
            );
            if (chatGptCredential.fedRamp) {
              outgoing.headers.set('X-OpenAI-Fedramp', 'true');
            }
          }
          if (affinity case final _ChatGptAffinity value) {
            outgoing.headers.set('session-id', value.id);
            if (value.state?.data['turnState'] case final String token) {
              outgoing.headers.set('x-codex-turn-state', token);
            }
          }
          outgoing.write(body);
          current.stage = 'response_headers';
          final HttpClientResponse response = await outgoing.close();
          if (!current.active) {
            await _containCleanup(() async {
              try {
                outgoing.abort();
              } finally {
                await response.listen((_) {}, onError: (Object _) {}).cancel();
              }
            }, cleanupTimeout);
            return;
          }
          current.response = response;
          current.timer?.cancel();
          status = response.statusCode;
          // Capture before any SSE consumer can cancel at the semantic terminal.
          if (affinity != null) {
            for (final String token
                in response.headers['x-codex-turn-state'] ?? const <String>[]) {
              // A value rejected for replay is still private in diagnostics.
              if (token.isNotEmpty) affinitySecrets.add(token);
            }
          }
          if (response.statusCode >= 200 && response.statusCode < 300) {
            affinity?.capture(response.headers, chatGptCredential!);
          }
          final List<String> sensitiveValues = <String>[
            ?_apiKey,
            if (chatGptCredential case final OpenAiChatGptCredential value)
              value.accessToken,
            if (chatGptCredential case final OpenAiChatGptCredential value)
              value.accountId,
            ...affinitySecrets,
          ];
          requestId = _redactProviderText(
            _diagnosticHeader(response.headers, 'x-request-id') ??
                _diagnosticHeader(response.headers, 'x-oai-request-id'),
            sensitiveValues,
          );
          if (response.statusCode < 200 || response.statusCode >= 300) {
            final _BoundedBodyCapture capture = _BoundedBodyCapture(response);
            current.stage = 'error_body';
            current.errorBody = capture;
            current.timer = Timer(responseOpenTimeout, () {
              transportError(TimeoutException(''));
            });
            final _BoundedBody bodyCapture = await capture.result;
            if (!current.active) return;
            final _HttpFailure failure = _classifyHttpFailure(
              response.statusCode,
              bodyCapture.text,
              requestId,
              _redactProviderText(
                _diagnosticHeader(
                  response.headers,
                  HttpHeaders.retryAfterHeader,
                ),
                sensitiveValues,
              ),
              bodyCapture.truncated,
              sensitiveValues,
            );
            current.finish(
              _failedTerminal(
                failure.kind,
                failure.code,
                failure.message,
                details: failure.details,
                requestId: requestId,
              ),
              unauthorized: response.statusCode == HttpStatus.unauthorized,
            );
            return;
          }
          final _SseRecordDecoder decoder = _SseRecordDecoder();
          final _ResponsesNormalizer normalizer = _ResponsesNormalizer(
            requestId: requestId,
            emit: (ModelProviderEvent event) {
              if (!current.active || cancelled || settled) return;
              if (event.kind == ModelProviderEventKind.terminal) {
                current.finish(event.terminal!);
              } else {
                published = true;
                controller.add(event);
              }
            },
          );
          current.stage = 'sse';
          void resetInactivity() {
            current.timer?.cancel();
            if (!current.active || controller.isPaused) return;
            current.timer = Timer(inactivityTimeout, () {
              reject(
                ModelProviderFailureKind.transport,
                'sse_inactivity',
                'The OpenAI response stream exceeded the inactivity deadline.',
                retryable: true,
                details: const {'cause': 'inactivity'},
              );
            });
          }

          current.resumeInactivity = resetInactivity;
          resetInactivity();
          current.lines = response
              .map((List<int> bytes) {
                // Count bytes before UTF-8/line/SSE framing, including keepalives
                // and partial records, rather than requiring semantic progress.
                resetInactivity();
                return bytes;
              })
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen(
                (String line) {
                  if (!current.active) return;
                  try {
                    for (final String data in decoder.addLine(line)) {
                      normalizer.addData(data);
                    }
                  } on _OpenAiResponseException catch (error) {
                    reject(
                      ModelProviderFailureKind.malformedResponse,
                      error.code,
                      error.message,
                      details: const {'cause': 'invalid_sse'},
                    );
                  } on Object {
                    reject(
                      ModelProviderFailureKind.malformedResponse,
                      'malformed_stream',
                      'The OpenAI response stream was malformed.',
                      details: const {'cause': 'invalid_sse'},
                    );
                  }
                },
                onError: (Object error, StackTrace stackTrace) {
                  if (!current.active) return;
                  if (error is FormatException) {
                    reject(
                      ModelProviderFailureKind.malformedResponse,
                      'invalid_utf8',
                      'The OpenAI response stream was not valid UTF-8.',
                      details: const {'cause': 'invalid_utf8'},
                    );
                  } else {
                    transportError(error);
                  }
                },
                onDone: () {
                  if (!current.active) return;
                  try {
                    decoder.finish();
                  } on _OpenAiResponseException catch (error) {
                    reject(
                      ModelProviderFailureKind.malformedResponse,
                      error.code,
                      error.message,
                      details: const {'cause': 'invalid_sse'},
                    );
                    return;
                  }
                  reject(
                    ModelProviderFailureKind.malformedResponse,
                    'missing_terminal',
                    'The OpenAI response ended before a semantic terminal.',
                    retryable: true,
                    details: const {'cause': 'premature_eof'},
                  );
                },
              );
          if (controller.isPaused) current.lines!.pause();
        } on _OpenAiResponseException catch (error) {
          reject(
            ModelProviderFailureKind.malformedResponse,
            error.code,
            error.message,
            details: const {'cause': 'invalid_headers'},
          );
        } on Object catch (error) {
          transportError(error);
        }
      }

      try {
        OpenAiChatGptAuthorization? authorization = await _chatGptAuth
            ?.authorization();
        bool recoveredAuthorization = false;
        while (!cancelled && !settled && httpAttempts < 3) {
          final current = _OpenAiHttpAttempt(cleanupTimeout);
          attempt = current;
          httpAttempts++;
          unawaited(send(current, authorization));
          final result = await current.result.future;
          if (result == null || cancelled) return;
          final retryTransport =
              result.retryable &&
              !published &&
              transportRetries == 0 &&
              httpAttempts < 3;
          final recoverAuthorization =
              result.unauthorized &&
              !published &&
              _chatGptAuth != null &&
              !recoveredAuthorization &&
              httpAttempts < 3;
          // Terminal delivery does not wait on potentially slow transport cleanup.
          if (!retryTransport && !recoverAuthorization) {
            emitTerminal(result.terminal);
            await current.stop();
            return;
          }
          await current.stop();
          if (cancelled) return;
          if (recoverAuthorization) {
            recoveredAuthorization = true;
            authorization = await _chatGptAuth.recoverUnauthorized(
              authorization!.revision,
            );
          } else {
            transportRetries++;
            final wait = Completer<void>();
            retryWait = wait;
            retryTimer = Timer(transportRetryDelay, wait.complete);
            await wait.future;
          }
        }
      } on OpenAiAuthenticationException catch (error) {
        fail(
          switch (error.failureKind) {
            OpenAiAuthenticationFailureKind.authentication =>
              ModelProviderFailureKind.authentication,
            OpenAiAuthenticationFailureKind.rateLimited =>
              ModelProviderFailureKind.rateLimited,
            OpenAiAuthenticationFailureKind.unavailable =>
              ModelProviderFailureKind.unavailable,
            OpenAiAuthenticationFailureKind.transport =>
              ModelProviderFailureKind.transport,
            OpenAiAuthenticationFailureKind.malformedResponse =>
              ModelProviderFailureKind.malformedResponse,
          },
          error.code,
          error.message,
          details: {
            'transportStage': 'authorization',
            'cause': 'authentication',
            ...error.safeDetails,
          },
        );
      } on Object {
        fail(
          ModelProviderFailureKind.transport,
          'transport_error',
          'The OpenAI transport failed.',
          details: const {'cause': 'unknown'},
        );
      }
    }

    controller = StreamController<ModelProviderEvent>(
      sync: true,
      onListen: () {
        if (_closed) {
          fail(
            ModelProviderFailureKind.unavailable,
            'provider_closed',
            'The OpenAI provider is closed.',
          );
          return;
        }
        _invocations.add(cancel);
        unawaited(start());
      },
      onPause: () {
        if (attempt?.stage == 'sse') attempt?.timer?.cancel();
        attempt?.lines?.pause();
      },
      onResume: () {
        attempt?.resumeInactivity?.call();
        attempt?.lines?.resume();
      },
      onCancel: cancel,
    );
    return controller.stream;
  }
}

// Each attempt owns its fence and resources. Completing it revokes callbacks
// synchronously, even if the platform cannot yet finish acquisition/cancellation.
final class _OpenAiHttpAttempt {
  _OpenAiHttpAttempt(this.cleanupTimeout);

  final Duration cleanupTimeout;
  final Completer<_OpenAiAttemptResult?> result = Completer();
  HttpClientRequest? request;
  HttpClientResponse? response;
  StreamSubscription<String>? lines;
  _BoundedBodyCapture? errorBody;
  Timer? timer;
  void Function()? resumeInactivity;
  String stage = 'connection';
  bool active = true;
  Future<void>? _stopping;

  void finish(
    ModelProviderTerminal terminal, {
    bool retryable = false,
    bool unauthorized = false,
  }) {
    if (!active) return;
    active = false;
    timer?.cancel();
    result.complete(_OpenAiAttemptResult(terminal, retryable, unauthorized));
  }

  Future<void> stop() {
    if (_stopping case final existing?) return existing;
    active = false;
    timer?.cancel();
    if (!result.isCompleted) result.complete(null);
    return _stopping = Future<void>.microtask(
      () => _containCleanup(() async {
        try {
          request?.abort();
        } finally {
          await Future.wait<void>([
            if (lines != null) Future.sync(lines!.cancel),
            if (errorBody != null) Future.sync(errorBody!.cancel),
            if (lines == null && errorBody == null && response != null)
              Future.sync(
                () => response!.listen((_) {}, onError: (Object _) {}).cancel(),
              ),
          ]);
        }
      }, cleanupTimeout),
    );
  }
}

final class _OpenAiAttemptResult {
  const _OpenAiAttemptResult(this.terminal, this.retryable, this.unauthorized);
  final ModelProviderTerminal terminal;
  final bool retryable;
  final bool unauthorized;
}

Future<void> _containCleanup(
  Future<void> Function() cleanup,
  Duration timeout,
) async {
  try {
    await Future<void>.sync(cleanup).timeout(timeout);
  } on Object {
    // The attempt is already fenced; late cleanup errors cannot change settlement
    // or escape. Never force-close a client shared by another invocation.
  }
}

// Invocation-local only. The caller owns the envelope's logical-turn lifetime.
final class _ChatGptAffinity {
  _ChatGptAffinity(
    ModelProviderAffinity affinity, {
    required String model,
    required String instanceId,
    required Uri endpoint,
  }) : id = affinity.id,
       state = affinity.state,
       compatibility = <String, Object?>{
         'version': 1,
         'scope': affinity.id,
         'model': model,
         'instanceId': instanceId,
         'endpoint': endpoint.toString(),
       } {
    if (!_safeAffinityHeader(id, maximumLength: 256) || id.contains(' ')) {
      throw const _OpenAiRequestException(
        ModelProviderFailureKind.invalidRequest,
        'invalid_affinity_id',
        'The ChatGPT affinity ID is not a safe bounded header value.',
      );
    }
    final ModelProviderNativeEnvelope? envelope = state;
    if (envelope == null) return;
    if (envelope.kind != 'openai.chatgpt.affinity.v1' ||
        envelope.compatibility['version'] != 1) {
      throw const _OpenAiRequestException(
        ModelProviderFailureKind.unsupportedRequest,
        'unsupported_affinity_state',
        'The ChatGPT affinity state kind or version is unsupported.',
      );
    }
    if (envelope.compatibility.length != compatibility.length ||
        compatibility.entries.any(
          (entry) => envelope.compatibility[entry.key] != entry.value,
        )) {
      throw const _OpenAiRequestException(
        ModelProviderFailureKind.invalidRequest,
        'incompatible_affinity_state',
        'The ChatGPT affinity state belongs to a different request scope.',
      );
    }
    if (envelope.data.length != 3 ||
        !_safeAffinityHeader(envelope.data['turnState']) ||
        !_safeAffinityHeader(envelope.data['accountId']) ||
        envelope.data['fedRamp'] is! bool) {
      throw const _OpenAiRequestException(
        ModelProviderFailureKind.invalidRequest,
        'invalid_affinity_state',
        'The ChatGPT affinity state is malformed.',
      );
    }
  }

  final String id;
  final Map<String, Object?> compatibility;
  ModelProviderNativeEnvelope? state;

  void bind(OpenAiChatGptCredential credential) {
    if (state?.data['accountId'] != credential.accountId ||
        state?.data['fedRamp'] != credential.fedRamp) {
      state = null;
    }
  }

  void capture(HttpHeaders headers, OpenAiChatGptCredential credential) {
    // Codex's HTTP turn-state contract is first usable value wins, not rotation.
    if (state != null) return;
    final List<String>? values = headers['x-codex-turn-state'];
    if (values == null ||
        values.length != 1 ||
        !_safeAffinityHeader(values.single)) {
      return;
    }
    state = ModelProviderNativeEnvelope(
      kind: 'openai.chatgpt.affinity.v1',
      compatibility: compatibility,
      data: <String, Object?>{
        'turnState': values.single,
        'accountId': credential.accountId,
        'fedRamp': credential.fedRamp,
      },
    );
  }
}

bool _safeAffinityHeader(Object? value, {int maximumLength = 8192}) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= maximumLength &&
    value == value.trim() &&
    value.codeUnits.every((int code) => code >= 0x20 && code <= 0x7e);

String _validateApiKey(String apiKey) {
  if (apiKey.trim().isEmpty || apiKey != apiKey.trim()) {
    throw const FormatException('OpenAI API key must be nonempty and trimmed.');
  }
  if (apiKey.contains('\r') || apiKey.contains('\n')) {
    throw const FormatException('OpenAI API key contains invalid characters.');
  }
  return apiKey;
}

Map<String, Object?> _lowerRequest(
  ModelProviderRequest request,
  _OpenAiRequestProfile profile,
) {
  if (request.providerOptions.isNotEmpty) {
    throw const _OpenAiRequestException(
      ModelProviderFailureKind.unsupportedRequest,
      'unsupported_provider_options',
      'OpenAI provider options are not supported in this phase.',
    );
  }
  if (request.nativeState != null) {
    throw const _OpenAiRequestException(
      ModelProviderFailureKind.unsupportedRequest,
      'unsupported_native_state',
      'Invocation-native continuation is not supported.',
    );
  }
  if (profile == _OpenAiRequestProfile.chatGpt &&
      request.maxOutputTokens != null) {
    throw const _OpenAiRequestException(
      ModelProviderFailureKind.unsupportedRequest,
      'chatgpt_max_output_tokens_unsupported',
      'The experimental ChatGPT Responses profile does not support an explicit output-token cap.',
    );
  }
  return <String, Object?>{
    'model': request.model,
    'instructions': request.instructions,
    'input': request.input.map(_lowerInput).toList(growable: false),
    'tools': request.tools
        .map(
          (ModelProviderTool tool) => <String, Object?>{
            'type': 'function',
            'name': tool.name,
            'description': tool.description,
            'parameters': tool.argumentsSchema,
          },
        )
        .toList(growable: false),
    'tool_choice': switch (request.toolChoice) {
      ModelProviderToolChoice.auto => 'auto',
      ModelProviderToolChoice.none => 'none',
    },
    // Permit multiple calls in one response, not concurrent host execution.
    'parallel_tool_calls': true,
    if (request.maxOutputTokens != null)
      'max_output_tokens': request.maxOutputTokens,
    if (_reasoningSummaryModels.contains(request.model))
      'reasoning': <String, Object?>{'summary': 'auto'},
    'include': <String>['reasoning.encrypted_content'],
    'store': false,
    'stream': true,
  };
}

enum _OpenAiRequestProfile { apiKey, chatGpt }

Map<String, Object?> _lowerInput(ModelProviderInput input) {
  switch (input.kind) {
    case ModelProviderInputKind.message:
      final ModelProviderMessage message = input.message!;
      final Map<String, Object?> item = <String, Object?>{
        'type': 'message',
        'role': message.role == ModelProviderMessageRole.user
            ? 'user'
            : 'assistant',
        'content': message.content
            .map(
              (ModelProviderContent content) => <String, Object?>{
                'type': message.role == ModelProviderMessageRole.user
                    ? 'input_text'
                    : 'output_text',
                'text': content.text,
                if (message.role == ModelProviderMessageRole.assistant)
                  'annotations': <Object?>[],
              },
            )
            .toList(growable: false),
      };
      if (message.role == ModelProviderMessageRole.assistant) {
        if (input.itemId != null) item['id'] = input.itemId;
        final Map<String, Object?> metadata = _semanticMetadata(
          input.nativeMetadata,
          expectedType: 'message',
        );
        if (metadata['phase'] case final String phase) item['phase'] = phase;
        item['status'] = 'completed';
      } else if (input.itemId != null || input.nativeMetadata != null) {
        throw const _OpenAiRequestException(
          ModelProviderFailureKind.invalidRequest,
          'invalid_user_metadata',
          'User input cannot carry OpenAI output-item metadata.',
        );
      }
      return item;
    case ModelProviderInputKind.toolProposal:
      final ModelProviderToolProposal proposal = input.toolProposal!;
      final Map<String, Object?> metadata = _semanticMetadata(
        input.nativeMetadata,
        expectedType: 'function_call',
      );
      return <String, Object?>{
        'type': 'function_call',
        if (input.itemId != null) 'id': input.itemId,
        'call_id': proposal.callId,
        'name': proposal.name,
        'arguments': jsonEncode(proposal.arguments),
        'status': 'completed',
        if (metadata['namespace'] case final String namespace)
          'namespace': namespace,
      };
    case ModelProviderInputKind.toolOutcome:
      if (input.itemId != null || input.nativeMetadata != null) {
        throw const _OpenAiRequestException(
          ModelProviderFailureKind.invalidRequest,
          'invalid_tool_output_metadata',
          'Tool outcomes cannot carry OpenAI output-item metadata.',
        );
      }
      return <String, Object?>{
        'type': 'function_call_output',
        'call_id': input.toolOutcome!.callId,
        'output': input.toolOutcome!.content,
      };
    case ModelProviderInputKind.nativeItem:
      final ModelProviderNativeEnvelope envelope = input.nativeMetadata!;
      if (envelope.kind != openAiResponsesItemKind ||
          envelope.compatibility['version'] != openAiResponsesItemVersion ||
          envelope.compatibility.length != 1 ||
          envelope.data['item'] is! Map<String, Object?> ||
          envelope.data.length != 1) {
        throw const _OpenAiRequestException(
          ModelProviderFailureKind.invalidRequest,
          'incompatible_native_item',
          'The OpenAI native item envelope is incompatible.',
        );
      }
      final Map<String, Object?> item = Map<String, Object?>.from(
        envelope.data['item']! as Map<String, Object?>,
      );
      final Object? itemType = item['type'];
      if (itemType != 'reasoning' && itemType != 'compaction') {
        throw const _OpenAiRequestException(
          ModelProviderFailureKind.unsupportedRequest,
          'unsupported_native_item',
          'The OpenAI native item type is not safe for replay.',
        );
      }
      if (input.itemId != null && item['id'] != input.itemId) {
        throw const _OpenAiRequestException(
          ModelProviderFailureKind.invalidRequest,
          'conflicting_native_item_id',
          'The native item ID conflicts with its envelope.',
        );
      }
      return item;
  }
}

Map<String, Object?> _semanticMetadata(
  ModelProviderNativeEnvelope? envelope, {
  required String expectedType,
}) {
  if (envelope == null) return const <String, Object?>{};
  if (envelope.kind != _semanticMetadataKind ||
      envelope.compatibility['version'] != 1 ||
      envelope.compatibility['itemType'] != expectedType ||
      envelope.compatibility.length != 2) {
    throw const _OpenAiRequestException(
      ModelProviderFailureKind.invalidRequest,
      'incompatible_item_metadata',
      'The OpenAI semantic-item metadata is incompatible.',
    );
  }
  const Set<String> allowed = <String>{'phase', 'namespace'};
  if (envelope.data.keys.any((String key) => !allowed.contains(key)) ||
      envelope.data.values.any((Object? value) => value is! String)) {
    throw const _OpenAiRequestException(
      ModelProviderFailureKind.invalidRequest,
      'malformed_item_metadata',
      'The OpenAI semantic-item metadata is malformed.',
    );
  }
  return envelope.data;
}

final class _SseRecordDecoder {
  final List<String> _data = <String>[];

  Iterable<String> addLine(String line) sync* {
    if (line.isEmpty) {
      if (_data.isNotEmpty) {
        yield _data.join('\n');
        _data.clear();
      }
      return;
    }
    if (line.startsWith(':')) return;
    final int separator = line.indexOf(':');
    final String field = separator < 0 ? line : line.substring(0, separator);
    String value = separator < 0 ? '' : line.substring(separator + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'data') _data.add(value);
  }

  void finish() {
    if (_data.isNotEmpty) {
      throw const _OpenAiResponseException(
        'unterminated_sse_event',
        'The OpenAI SSE stream ended within an event record.',
      );
    }
  }
}

final class _ResponsesNormalizer {
  _ResponsesNormalizer({required this.requestId, required this.emit});

  final String? requestId;
  final void Function(ModelProviderEvent) emit;
  bool settled = false;
  bool sawRefusal = false;

  void addData(String data) {
    if (settled) return;
    if (data == '[DONE]') {
      throw const _OpenAiResponseException(
        'unexpected_done_sentinel',
        'The OpenAI stream used a framing sentinel without a semantic terminal.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      throw const _OpenAiResponseException(
        'malformed_json',
        'An OpenAI SSE event did not contain valid JSON.',
      );
    }
    if (decoded is! Map<String, Object?> || decoded['type'] is! String) {
      throw const _OpenAiResponseException(
        'invalid_event',
        'An OpenAI SSE event has an invalid shape.',
      );
    }
    final String type = decoded['type']! as String;
    final Object? metadata = decoded['metadata'];
    // Codex status notifications are separate from the underlying event. Validate
    // both locations without treating either as output, routing, or retry authority.
    for (final Object? safety in <Object?>[
      decoded['safety_buffering'],
      if (type == 'response.metadata' &&
          metadata is Map<String, Object?> &&
          metadata['type'] == 'safety_buffering')
        metadata,
    ]) {
      if (safety == null || safety == false) continue;
      if (safety is! Map<String, Object?> ||
          safety['use_cases'] is! List<Object?> ||
          !(safety['use_cases']! as List<Object?>).every(
            (value) => value is String,
          ) ||
          safety['reasons'] is! List<Object?> ||
          !(safety['reasons']! as List<Object?>).every(
            (value) => value is String,
          ) ||
          (safety['retry_model'] != null && safety['retry_model'] is! String)) {
        throw const _OpenAiResponseException(
          'invalid_safety_metadata',
          'OpenAI safety-buffering metadata has an invalid shape.',
        );
      }
    }
    switch (type) {
      case 'response.metadata':
        if (metadata != null && metadata is! Map<String, Object?>) {
          throw const _OpenAiResponseException(
            'invalid_response_metadata',
            'OpenAI response metadata has an invalid shape.',
          );
        }
        if (metadata is Map<String, Object?> &&
            metadata.containsKey('type') &&
            metadata['type'] != 'safety_buffering') {
          throw const _OpenAiResponseException(
            'unsupported_response_metadata',
            'Typed OpenAI response metadata is not supported.',
          );
        }
        // Informational sideband is neither output nor terminal/affinity state.
        return;
      case 'keepalive':
      case 'response.created':
      case 'response.in_progress':
      case 'response.output_item.added':
      case 'response.content_part.added':
      case 'response.content_part.done':
      case 'response.output_text.done':
      case 'response.refusal.delta':
      case 'response.refusal.done':
      case 'response.function_call_arguments.delta':
      case 'response.function_call_arguments.done':
        return;
      case 'response.output_text.delta':
        final String delta = _requiredString(decoded, 'delta');
        if (delta.isEmpty) {
          throw const _OpenAiResponseException(
            'empty_text_delta',
            'An OpenAI text delta was empty.',
          );
        }
        emit(
          ModelProviderEvent(
            kind: ModelProviderEventKind.observation,
            observation: ModelProviderObservation(
              kind: ModelProviderObservationKind.textDelta,
              textDelta: delta,
              itemId: _optionalString(decoded['item_id']),
            ),
            output: null,
            terminal: null,
          ),
        );
        return;
      case 'response.output_item.done':
        _outputItem(_requiredMap(decoded, 'item'));
        return;
      case 'response.completed':
        _settleCompleted(_requiredMap(decoded, 'response'));
        return;
      case 'response.incomplete':
        _settleIncomplete(_requiredMap(decoded, 'response'));
        return;
      case 'response.failed':
        _settleFailed(_requiredMap(decoded, 'response'));
        return;
      case 'error':
        _settleError(decoded);
        return;
      default:
        if (type.startsWith('response.') &&
            (type.endsWith('.delta') ||
                type.endsWith('.added') ||
                type.endsWith('.done'))) {
          return;
        }
        throw _OpenAiResponseException(
          'unsupported_event',
          'Unsupported authoritative OpenAI event: $type.',
        );
    }
  }

  void _outputItem(Map<String, Object?> item) {
    final String type = _requiredString(item, 'type');
    final String? id = _optionalString(item['id']);
    switch (type) {
      case 'message':
        if (item['role'] != 'assistant' || item['content'] is! List<Object?>) {
          throw const _OpenAiResponseException(
            'invalid_message',
            'A completed OpenAI message has an invalid shape.',
          );
        }
        final List<Object?> content = item['content']! as List<Object?>;
        final StringBuffer text = StringBuffer();
        final StringBuffer refusal = StringBuffer();
        for (final Object? part in content) {
          if (part is! Map<String, Object?> || part['type'] is! String) {
            throw const _OpenAiResponseException(
              'invalid_message_content',
              'A completed OpenAI message contains invalid content.',
            );
          }
          switch (part['type']) {
            case 'output_text':
              final Object? annotations = part['annotations'];
              if (annotations is! List<Object?>) {
                throw const _OpenAiResponseException(
                  'invalid_output_text_annotations',
                  'OpenAI output text annotations were missing or malformed.',
                );
              }
              if (annotations.isNotEmpty) {
                throw const _OpenAiResponseException(
                  'unsupported_output_text_annotations',
                  'OpenAI output text annotations are not supported in B4.',
                );
              }
              text.write(_requiredString(part, 'text'));
            case 'refusal':
              refusal.write(_requiredString(part, 'refusal'));
            default:
              throw const _OpenAiResponseException(
                'unsupported_message_content',
                'A completed OpenAI message contains unsupported content.',
              );
          }
        }
        if (text.isNotEmpty && refusal.isNotEmpty) {
          throw const _OpenAiResponseException(
            'mixed_refusal',
            'A completed OpenAI message mixed text and refusal content.',
          );
        }
        final String output = refusal.isNotEmpty
            ? refusal.toString()
            : text.toString();
        if (output.isEmpty) {
          throw const _OpenAiResponseException(
            'empty_message',
            'A completed OpenAI message had no output.',
          );
        }
        sawRefusal = sawRefusal || refusal.isNotEmpty;
        final String? phase = _optionalString(item['phase']);
        emit(
          _outputEvent(
            ModelProviderOutput(
              kind: ModelProviderOutputKind.text,
              text: output,
              toolProposal: null,
              itemId: id,
              nativeMetadata: phase == null
                  ? null
                  : ModelProviderNativeEnvelope(
                      kind: _semanticMetadataKind,
                      compatibility: const <String, Object?>{
                        'version': 1,
                        'itemType': 'message',
                      },
                      data: <String, Object?>{'phase': phase},
                    ),
              nativePresentation: null,
            ),
          ),
        );
        return;
      case 'function_call':
        final String callId = _requiredNonEmptyString(item, 'call_id');
        final String name = _requiredNonEmptyString(item, 'name');
        final String encodedArguments = _requiredString(item, 'arguments');
        final Object? arguments;
        try {
          arguments = jsonDecode(encodedArguments);
        } on FormatException {
          throw const _OpenAiResponseException(
            'malformed_function_arguments',
            'OpenAI function arguments were not valid JSON.',
          );
        }
        if (arguments is! Map<String, Object?>) {
          throw const _OpenAiResponseException(
            'non_object_function_arguments',
            'OpenAI function arguments were not a JSON object.',
          );
        }
        final String? namespace = _optionalString(item['namespace']);
        emit(
          _outputEvent(
            ModelProviderOutput(
              kind: ModelProviderOutputKind.toolProposal,
              text: null,
              toolProposal: ModelProviderToolProposal(
                callId: callId,
                name: name,
                arguments: arguments,
              ),
              itemId: id,
              nativeMetadata: namespace == null
                  ? null
                  : ModelProviderNativeEnvelope(
                      kind: _semanticMetadataKind,
                      compatibility: const <String, Object?>{
                        'version': 1,
                        'itemType': 'function_call',
                      },
                      data: <String, Object?>{'namespace': namespace},
                    ),
              nativePresentation: null,
            ),
          ),
        );
        return;
      case 'reasoning':
      case 'compaction':
        final ModelProviderNativeEnvelope nativeMetadata =
            ModelProviderNativeEnvelope(
              kind: openAiResponsesItemKind,
              compatibility: const <String, Object?>{
                'version': openAiResponsesItemVersion,
              },
              data: <String, Object?>{'item': item},
            );
        emit(
          _outputEvent(
            ModelProviderOutput(
              kind: ModelProviderOutputKind.nativeItem,
              text: null,
              toolProposal: null,
              itemId: id,
              nativeMetadata: nativeMetadata,
              nativePresentation: projectOpenAiReasoningSummary(nativeMetadata),
            ),
          ),
        );
        return;
      case 'web_search_call':
      case 'file_search_call':
      case 'computer_call':
      case 'code_interpreter_call':
      case 'custom_tool_call':
      case 'mcp_call':
        throw _OpenAiResponseException(
          'provider_hosted_tool_output',
          'OpenAI emitted unsupported provider-hosted tool output: $type.',
        );
      default:
        throw _OpenAiResponseException(
          'unsupported_output_item',
          'OpenAI emitted an unsupported completed output item: $type.',
        );
    }
  }

  void _settleCompleted(Map<String, Object?> response) {
    final ModelProviderTerminal metadata = _terminalMetadata(response);
    settled = true;
    emit(
      _terminalEvent(
        ModelProviderTerminal(
          settlement: sawRefusal
              ? ModelProviderSettlement.refused
              : ModelProviderSettlement.completed,
          incompleteReason: null,
          failure: null,
          providerStopReason: sawRefusal ? 'refusal' : 'completed',
          usage: metadata.usage,
          effectiveModel: metadata.effectiveModel,
          responseId: metadata.responseId,
          requestId: metadata.requestId,
          nativeState: null,
          affinityState: null,
        ),
      ),
    );
  }

  void _settleIncomplete(Map<String, Object?> response) {
    final ModelProviderTerminal metadata = _terminalMetadata(response);
    final Map<String, Object?>? details =
        response['incomplete_details'] as Map<String, Object?>?;
    final String reason = _optionalString(details?['reason']) ?? 'unknown';
    settled = true;
    emit(
      _terminalEvent(
        ModelProviderTerminal(
          settlement: ModelProviderSettlement.incomplete,
          incompleteReason: reason == 'max_output_tokens'
              ? ModelProviderIncompleteReason.outputLimit
              : ModelProviderIncompleteReason.other,
          failure: null,
          providerStopReason: reason,
          usage: metadata.usage,
          effectiveModel: metadata.effectiveModel,
          responseId: metadata.responseId,
          requestId: metadata.requestId,
          nativeState: null,
          affinityState: null,
        ),
      ),
    );
  }

  void _settleFailed(Map<String, Object?> response) {
    final ModelProviderTerminal metadata = _terminalMetadata(response);
    final Map<String, Object?> error = response['error'] is Map<String, Object?>
        ? response['error']! as Map<String, Object?>
        : const <String, Object?>{};
    settled = true;
    emit(
      _terminalEvent(
        ModelProviderTerminal(
          settlement: ModelProviderSettlement.failed,
          incompleteReason: null,
          failure: ModelProviderFailure(
            kind: ModelProviderFailureKind.providerFailure,
            providerCode: _optionalString(error['code']),
            providerMessage:
                _optionalString(error['message']) ??
                'OpenAI generation failed.',
            providerDetails: const <String, Object?>{},
          ),
          providerStopReason: 'failed',
          usage: metadata.usage,
          effectiveModel: metadata.effectiveModel,
          responseId: metadata.responseId,
          requestId: metadata.requestId,
          nativeState: null,
          affinityState: null,
        ),
      ),
    );
  }

  void _settleError(Map<String, Object?> event) {
    final Map<String, Object?> error = event['error'] is Map<String, Object?>
        ? event['error']! as Map<String, Object?>
        : event;
    settled = true;
    emit(
      _terminalEvent(
        _failedTerminal(
          ModelProviderFailureKind.providerFailure,
          _optionalString(error['code']) ??
              _optionalString(error['type']) ??
              'provider_error',
          _optionalString(error['message']) ?? 'OpenAI reported an error.',
          requestId: requestId,
        ),
      ),
    );
  }

  ModelProviderTerminal _terminalMetadata(Map<String, Object?> response) {
    final Map<String, Object?>? usage =
        response['usage'] as Map<String, Object?>?;
    final Map<String, Object?>? inputDetails =
        usage?['input_tokens_details'] as Map<String, Object?>?;
    final Map<String, Object?>? outputDetails =
        usage?['output_tokens_details'] as Map<String, Object?>?;
    return ModelProviderTerminal(
      settlement: ModelProviderSettlement.completed,
      incompleteReason: null,
      failure: null,
      providerStopReason: null,
      usage: usage == null
          ? null
          : ModelProviderUsage(
              inputTokens: _optionalInt(usage['input_tokens']),
              outputTokens: _optionalInt(usage['output_tokens']),
              cacheReadTokens: _optionalInt(inputDetails?['cached_tokens']),
              cacheWriteTokens: _optionalInt(
                inputDetails?['cache_write_tokens'],
              ),
              providerDetails: <String, Object?>{
                if (_optionalInt(usage['total_tokens']) case final int value)
                  'totalTokens': value,
                if (_optionalInt(outputDetails?['reasoning_tokens'])
                    case final int value)
                  'reasoningTokens': value,
              },
            ),
      effectiveModel: _optionalNonBlankString(response['model']),
      responseId: _optionalString(response['id']),
      requestId: requestId,
      nativeState: null,
      affinityState: null,
    );
  }
}

final class _BoundedBodyCapture {
  _BoundedBodyCapture(HttpClientResponse response) {
    _subscription = response.listen(
      _add,
      onError: _fail,
      onDone: _finishNaturally,
    );
  }

  final BytesBuilder _bytes = BytesBuilder(copy: false);
  final Completer<_BoundedBody> _result = Completer<_BoundedBody>();
  late final StreamSubscription<List<int>> _subscription;
  Future<void>? _cancellation;

  Future<_BoundedBody> get result => _result.future;

  void _add(List<int> chunk) {
    if (_result.isCompleted) return;
    final int remaining = _maximumErrorBodyBytes - _bytes.length;
    if (chunk.length >= remaining) {
      if (remaining > 0) {
        _bytes.add(chunk.take(remaining).toList(growable: false));
      }
      _result.complete(_captured(truncated: true));
      return;
    }
    _bytes.add(chunk);
  }

  void _finishNaturally() {
    if (!_result.isCompleted) {
      _result.complete(_captured(truncated: false));
    }
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (!_result.isCompleted) _result.completeError(error, stackTrace);
  }

  Future<void> cancel() {
    final Future<void>? existing = _cancellation;
    if (existing != null) return existing;
    if (!_result.isCompleted) _result.complete(_captured(truncated: true));
    final Future<void> operation = _subscription.cancel();
    _cancellation = operation;
    return operation;
  }

  _BoundedBody _captured({required bool truncated}) => _BoundedBody(
    utf8.decode(_bytes.takeBytes(), allowMalformed: true),
    truncated,
  );
}

_HttpFailure _classifyHttpFailure(
  int status,
  String body,
  String? requestId,
  String? retryAfter,
  bool truncated,
  List<String> sensitiveValues,
) {
  String? code;
  String? message;
  try {
    final Object? decoded = jsonDecode(body);
    if (decoded is Map<String, Object?> &&
        decoded['error'] is Map<String, Object?>) {
      final Map<String, Object?> error =
          decoded['error']! as Map<String, Object?>;
      code =
          _optionalNonBlankString(error['code']) ??
          _optionalNonBlankString(error['type']);
      message = _optionalNonBlankString(error['message']);
    } else if (decoded is Map<String, Object?>) {
      code = _optionalNonBlankString(decoded['code']);
      message =
          _optionalNonBlankString(decoded['detail']) ??
          _optionalNonBlankString(decoded['message']);
    }
  } on FormatException {
    // The bounded raw body is deliberately not retained in diagnostics.
  }
  code = _redactProviderText(code, sensitiveValues);
  message = _redactProviderText(message, sensitiveValues);
  final ModelProviderFailureKind kind = switch (status) {
    400 => ModelProviderFailureKind.invalidRequest,
    401 => ModelProviderFailureKind.authentication,
    403 => ModelProviderFailureKind.permission,
    404 => ModelProviderFailureKind.unsupportedRequest,
    429 => ModelProviderFailureKind.rateLimited,
    >= 500 => ModelProviderFailureKind.unavailable,
    _ => ModelProviderFailureKind.providerFailure,
  };
  return _HttpFailure(
    kind,
    code ?? 'http_$status',
    message ?? 'OpenAI rejected the request with HTTP $status.',
    <String, Object?>{
      'status': status,
      'requestId': ?requestId,
      'retryAfter': ?retryAfter,
      if (truncated) 'responseBodyTruncated': true,
    },
  );
}

ModelProviderEvent _outputEvent(ModelProviderOutput output) =>
    ModelProviderEvent(
      kind: ModelProviderEventKind.output,
      observation: null,
      output: output,
      terminal: null,
    );

ModelProviderEvent _terminalEvent(ModelProviderTerminal terminal) =>
    ModelProviderEvent(
      kind: ModelProviderEventKind.terminal,
      observation: null,
      output: null,
      terminal: terminal,
    );

ModelProviderTerminal _failedTerminal(
  ModelProviderFailureKind kind,
  String code,
  String message, {
  Map<String, Object?> details = const <String, Object?>{},
  String? requestId,
}) => ModelProviderTerminal(
  settlement: ModelProviderSettlement.failed,
  incompleteReason: null,
  failure: ModelProviderFailure(
    kind: kind,
    providerCode: code,
    providerMessage: message,
    providerDetails: details,
  ),
  providerStopReason: 'failed',
  usage: null,
  effectiveModel: null,
  responseId: null,
  requestId: requestId,
  nativeState: null,
  affinityState: null,
);

Map<String, Object?> _requiredMap(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is Map<String, Object?>) return value;
  throw _OpenAiResponseException(
    'missing_$key',
    'The OpenAI event is missing required $key data.',
  );
}

String _requiredString(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is String) return value;
  throw _OpenAiResponseException(
    'missing_$key',
    'The OpenAI event is missing required $key text.',
  );
}

String _requiredNonEmptyString(Map<String, Object?> map, String key) {
  final String value = _requiredString(map, key);
  if (value.trim().isNotEmpty) return value;
  throw _OpenAiResponseException(
    'empty_$key',
    'The OpenAI event contains empty required $key text.',
  );
}

String? _optionalString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

String? _optionalNonBlankString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

String? _diagnosticHeader(HttpHeaders headers, String name) {
  try {
    return _optionalNonBlankString(headers.value(name));
  } on HttpException {
    throw const _OpenAiResponseException(
      'invalid_response_headers',
      'The OpenAI response has ambiguous diagnostic headers.',
    );
  }
}

String? _redactProviderText(String? value, List<String> sensitiveValues) {
  if (value == null) return null;
  // Redacting a substring first would prevent matching the complete secret.
  final List<String> secrets =
      sensitiveValues
          .where((String sensitive) => sensitive.isNotEmpty)
          .toSet()
          .toList()
        ..sort(
          (String left, String right) => right.length.compareTo(left.length),
        );
  String redacted = value;
  for (final String sensitive in secrets) {
    redacted = redacted.replaceAll(sensitive, '[REDACTED]');
  }
  // Bound diagnostics only, after redaction so a boundary cannot expose part of
  // a secret. Semantic text and native output never pass through this function.
  return redacted.length <= 4096 ? redacted : redacted.substring(0, 4096);
}

int? _optionalInt(Object? value) => value is int && value >= 0 ? value : null;

final class _OpenAiRequestException implements Exception {
  const _OpenAiRequestException(this.kind, this.code, this.message);

  final ModelProviderFailureKind kind;
  final String code;
  final String message;
}

final class _OpenAiResponseException implements Exception {
  const _OpenAiResponseException(this.code, this.message);

  final String code;
  final String message;
}

final class _BoundedBody {
  const _BoundedBody(this.text, this.truncated);

  final String text;
  final bool truncated;
}

final class _HttpFailure {
  const _HttpFailure(this.kind, this.code, this.message, this.details);

  final ModelProviderFailureKind kind;
  final String code;
  final String message;
  final Map<String, Object?> details;
}
