import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_model_provider/adele_model_provider.dart';

import 'src/openai_chatgpt_auth.dart';

const String openAiPluginId = 'dev.adele.openai';
const String openAiApiKeyProviderId = 'dev.adele.openai.api-key';
const String openAiChatGptProviderId = 'dev.adele.openai.chatgpt-experimental';
const String openAiChatGptConfigurationContext = 'chatgpt-experimental';
const String _nativeItemKind = 'openai.responses.item.v1';
const String _semanticMetadataKind = 'openai.responses.semantic-item.v1';
const int _maximumErrorBodyBytes = 16 * 1024;

final class OpenAiModelProvider implements ModelProviderService {
  OpenAiModelProvider({
    required String apiKey,
    Uri? endpoint,
    HttpClient? httpClient,
  }) : _apiKey = _validateApiKey(apiKey),
       _chatGptAuth = null,
       _profile = _OpenAiRequestProfile.apiKey,
       _endpoint = endpoint ?? Uri.parse('https://api.openai.com/v1/responses'),
       _httpClient = httpClient ?? HttpClient(),
       _ownsHttpClient = httpClient == null {
    _validateEndpoint(_endpoint, endpoint);
  }

  OpenAiModelProvider.chatGpt({
    required OpenAiChatGptAuth auth,
    Uri? endpoint,
    HttpClient? httpClient,
  }) : _apiKey = null,
       _chatGptAuth = auth,
       _profile = _OpenAiRequestProfile.chatGpt,
       _endpoint =
           endpoint ??
           Uri.parse('https://chatgpt.com/backend-api/codex/responses'),
       _httpClient = httpClient ?? HttpClient(),
       _ownsHttpClient = httpClient == null {
    _validateEndpoint(_endpoint, endpoint);
  }

  static void _validateEndpoint(Uri value, Uri? argument) {
    if (!value.isAbsolute ||
        (value.scheme != 'http' && value.scheme != 'https')) {
      throw ArgumentError.value(argument, 'endpoint', 'Must be HTTP(S).');
    }
    if (value.scheme == 'http' && !_isLoopbackHost(value.host)) {
      throw ArgumentError.value(
        argument,
        'endpoint',
        'Plaintext OpenAI endpoints must be loopback.',
      );
    }
  }

  final String? _apiKey;
  final OpenAiChatGptAuth? _chatGptAuth;
  final _OpenAiRequestProfile _profile;
  final Uri _endpoint;
  final HttpClient _httpClient;
  final bool _ownsHttpClient;

  void close() {
    if (_ownsHttpClient) _httpClient.close();
  }

  @override
  Stream<ModelProviderEvent> invoke(ModelProviderRequest request) {
    late StreamController<ModelProviderEvent> controller;
    HttpClientRequest? outboundRequest;
    StreamSubscription<String>? lines;
    _BoundedBodyCapture? errorBodyCapture;
    bool cancelled = false;
    bool settled = false;
    Future<void>? stoppingFuture;

    Future<void> stopNetwork() {
      final Future<void>? existing = stoppingFuture;
      if (existing != null) return existing;
      late final Future<void> operation;
      operation = () async {
        outboundRequest?.abort();
        final StreamSubscription<String>? subscription = lines;
        if (subscription != null) await subscription.cancel();
        final _BoundedBodyCapture? capture = errorBodyCapture;
        if (capture != null) await capture.cancel();
      }();
      stoppingFuture = operation;
      return operation;
    }

    void emitTerminal(ModelProviderTerminal terminal) {
      if (cancelled || settled) return;
      settled = true;
      controller.add(_terminalEvent(terminal));
      unawaited(controller.close());
      unawaited(stopNetwork());
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
      final Map<String, Object?> body;
      try {
        body = _lowerRequest(request, _profile);
      } on _OpenAiRequestException catch (error) {
        fail(error.kind, error.code, error.message);
        return;
      } on Object {
        fail(
          ModelProviderFailureKind.invalidRequest,
          'invalid_request',
          'The model request could not be encoded.',
        );
        return;
      }
      Future<void> send({
        required bool recoveredAuthorization,
        OpenAiChatGptAuthorization? authorization,
      }) async {
        try {
          final OpenAiChatGptAuthorization? chatGptAuthorization =
              _chatGptAuth == null
              ? null
              : authorization ?? await _chatGptAuth.authorization();
          final OpenAiChatGptCredential? chatGptCredential =
              chatGptAuthorization?.credential;
          if (cancelled) return;
          final HttpClientRequest outgoing = await _httpClient.postUrl(
            _endpoint,
          );
          if (cancelled) {
            outgoing.abort();
            return;
          }
          outboundRequest = outgoing;
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
          outgoing.write(jsonEncode(body));
          final HttpClientResponse response = await outgoing.close();
          if (cancelled) {
            await response.detachSocket().then(
              (Socket socket) => socket.destroy(),
            );
            return;
          }
          final String? requestId = response.headers.value('x-request-id');
          if (response.statusCode < 200 || response.statusCode >= 300) {
            final _BoundedBodyCapture capture = _BoundedBodyCapture(response);
            errorBodyCapture = capture;
            if (stoppingFuture != null) {
              await capture.cancel();
              return;
            }
            final _BoundedBody bodyCapture = await capture.result;
            if (cancelled) return;
            if (response.statusCode == HttpStatus.unauthorized &&
                _chatGptAuth != null &&
                !recoveredAuthorization) {
              errorBodyCapture = null;
              final OpenAiChatGptAuthorization recovered = await _chatGptAuth
                  .recoverUnauthorized(chatGptAuthorization!.revision);
              if (!cancelled) {
                await send(
                  recoveredAuthorization: true,
                  authorization: recovered,
                );
              }
              return;
            }
            final _HttpFailure failure = _classifyHttpFailure(
              response.statusCode,
              bodyCapture.text,
              requestId,
              response.headers.value(HttpHeaders.retryAfterHeader),
              bodyCapture.truncated,
            );
            fail(
              failure.kind,
              failure.code,
              failure.message,
              details: failure.details,
              requestId: requestId,
            );
            return;
          }
          final _SseRecordDecoder decoder = _SseRecordDecoder();
          final _ResponsesNormalizer normalizer = _ResponsesNormalizer(
            requestedModel: request.model,
            requestId: requestId,
            emit: (ModelProviderEvent event) {
              if (cancelled || settled) return;
              if (event.kind == ModelProviderEventKind.terminal) {
                settled = true;
                controller.add(event);
                unawaited(controller.close());
                unawaited(stopNetwork());
              } else {
                controller.add(event);
              }
            },
          );
          lines = response
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen(
                (String line) {
                  if (cancelled || settled) return;
                  try {
                    for (final String data in decoder.addLine(line)) {
                      normalizer.addData(data);
                    }
                  } on _OpenAiResponseException catch (error) {
                    fail(
                      ModelProviderFailureKind.malformedResponse,
                      error.code,
                      error.message,
                      requestId: requestId,
                    );
                  } on Object {
                    fail(
                      ModelProviderFailureKind.malformedResponse,
                      'malformed_stream',
                      'The OpenAI response stream was malformed.',
                      requestId: requestId,
                    );
                  }
                },
                onError: (Object error, StackTrace stackTrace) {
                  if (cancelled || settled) return;
                  if (error is FormatException) {
                    fail(
                      ModelProviderFailureKind.malformedResponse,
                      'invalid_utf8',
                      'The OpenAI response stream was not valid UTF-8.',
                      requestId: requestId,
                    );
                  } else {
                    fail(
                      ModelProviderFailureKind.transport,
                      'stream_transport',
                      'The OpenAI response stream failed.',
                      requestId: requestId,
                    );
                  }
                },
                onDone: () {
                  if (cancelled || settled) return;
                  try {
                    decoder.finish();
                  } on _OpenAiResponseException catch (error) {
                    fail(
                      ModelProviderFailureKind.malformedResponse,
                      error.code,
                      error.message,
                      requestId: requestId,
                    );
                    return;
                  }
                  fail(
                    ModelProviderFailureKind.malformedResponse,
                    'missing_terminal',
                    'The OpenAI response ended before a semantic terminal.',
                    requestId: requestId,
                  );
                },
              );
          if (controller.isPaused) lines!.pause();
        } on OpenAiAuthenticationException catch (error) {
          if (!cancelled && !settled) {
            fail(
              ModelProviderFailureKind.authentication,
              error.code,
              error.message,
            );
          }
        } on SocketException {
          if (!cancelled && !settled) {
            fail(
              ModelProviderFailureKind.transport,
              'network_error',
              'The OpenAI request could not reach the provider.',
            );
          }
        } on HandshakeException {
          if (!cancelled && !settled) {
            fail(
              ModelProviderFailureKind.transport,
              'tls_error',
              'The OpenAI TLS connection failed.',
            );
          }
        } on HttpException {
          if (!cancelled && !settled) {
            fail(
              ModelProviderFailureKind.transport,
              'http_transport',
              'The OpenAI HTTP operation failed.',
            );
          }
        } on Object {
          if (!cancelled && !settled) {
            fail(
              ModelProviderFailureKind.transport,
              'transport_error',
              'The OpenAI transport failed.',
            );
          }
        }
      }

      await send(recoveredAuthorization: false);
    }

    controller = StreamController<ModelProviderEvent>(
      sync: true,
      onListen: () => unawaited(start()),
      onPause: () => lines?.pause(),
      onResume: () => lines?.resume(),
      onCancel: () async {
        cancelled = true;
        await stopNetwork();
      },
    );
    return controller.stream;
  }
}

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
    'parallel_tool_calls': false,
    if (request.maxOutputTokens != null)
      'max_output_tokens': request.maxOutputTokens,
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
      if (envelope.kind != _nativeItemKind ||
          envelope.compatibility['version'] != 1 ||
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
  _ResponsesNormalizer({
    required this.requestedModel,
    required this.requestId,
    required this.emit,
  });

  final String requestedModel;
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
    switch (type) {
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
            ),
          ),
        );
        return;
      case 'reasoning':
      case 'compaction':
        emit(
          _outputEvent(
            ModelProviderOutput(
              kind: ModelProviderOutputKind.nativeItem,
              text: null,
              toolProposal: null,
              itemId: id,
              nativeMetadata: ModelProviderNativeEnvelope(
                kind: _nativeItemKind,
                compatibility: const <String, Object?>{'version': 1},
                data: <String, Object?>{'item': item},
              ),
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
        ),
      ),
    );
  }

  void _settleError(Map<String, Object?> event) {
    settled = true;
    emit(
      _terminalEvent(
        _failedTerminal(
          ModelProviderFailureKind.providerFailure,
          _optionalString(event['code']) ?? 'provider_error',
          _optionalString(event['message']) ?? 'OpenAI reported an error.',
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
              cacheWriteTokens: null,
              providerDetails: <String, Object?>{
                if (_optionalInt(usage['total_tokens']) case final int value)
                  'totalTokens': value,
                if (_optionalInt(outputDetails?['reasoning_tokens'])
                    case final int value)
                  'reasoningTokens': value,
              },
            ),
      effectiveModel: _optionalString(response['model']) ?? requestedModel,
      responseId: _optionalString(response['id']),
      requestId: requestId,
      nativeState: null,
    );
  }
}

final class _BoundedBodyCapture {
  _BoundedBodyCapture(HttpClientResponse response) {
    _subscription = response.listen(
      _add,
      onError: _fail,
      onDone: _finishNaturally,
      cancelOnError: true,
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
      unawaited(cancel());
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
    final Future<void> operation = _subscription.cancel();
    _cancellation = operation;
    return operation;
  }

  _BoundedBody _captured({required bool truncated}) => _BoundedBody(
    utf8.decode(_bytes.takeBytes(), allowMalformed: true),
    truncated,
  );
}

bool _isLoopbackHost(String host) {
  if (host.toLowerCase() == 'localhost') return true;
  final InternetAddress? address = InternetAddress.tryParse(host);
  return address?.isLoopback ?? false;
}

_HttpFailure _classifyHttpFailure(
  int status,
  String body,
  String? requestId,
  String? retryAfter,
  bool truncated,
) {
  String? code;
  String? message;
  try {
    final Object? decoded = jsonDecode(body);
    if (decoded is Map<String, Object?> &&
        decoded['error'] is Map<String, Object?>) {
      final Map<String, Object?> error =
          decoded['error']! as Map<String, Object?>;
      code = _optionalString(error['code']) ?? _optionalString(error['type']);
      message = _optionalString(error['message']);
    }
  } on FormatException {
    // The bounded raw body is deliberately not retained in diagnostics.
  }
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
