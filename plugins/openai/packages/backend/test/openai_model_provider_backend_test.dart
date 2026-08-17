import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:openai_model_provider_backend/openai_model_provider_backend.dart';
import 'package:openai_model_provider_backend/src/openai_chatgpt_auth.dart';
import 'package:test/test.dart';

void main() {
  group('OpenAiModelProvider', () {
    test('rejects unusable credentials at construction', () {
      expect(() => OpenAiModelProvider(apiKey: ''), throwsFormatException);
      expect(
        () => OpenAiModelProvider(apiKey: ' fake-key '),
        throwsFormatException,
      );
      expect(
        () => OpenAiModelProvider(apiKey: 'fake\nkey'),
        throwsFormatException,
      );
    });

    test('allows HTTPS and loopback HTTP endpoints only', () {
      final List<OpenAiModelProvider> allowed = <OpenAiModelProvider>[
        OpenAiModelProvider(apiKey: 'fake-openai-key'),
        OpenAiModelProvider(
          apiKey: 'fake-openai-key',
          endpoint: Uri.parse('https://example.test/v1/responses'),
        ),
        OpenAiModelProvider(
          apiKey: 'fake-openai-key',
          endpoint: Uri.parse('http://localhost:8080/v1/responses'),
        ),
        OpenAiModelProvider(
          apiKey: 'fake-openai-key',
          endpoint: Uri.parse('http://127.0.0.1:8080/v1/responses'),
        ),
        OpenAiModelProvider(
          apiKey: 'fake-openai-key',
          endpoint: Uri.parse('http://[::1]:8080/v1/responses'),
        ),
      ];
      addTearDown(() {
        for (final OpenAiModelProvider provider in allowed) {
          provider.close();
        }
      });

      expect(
        () => OpenAiModelProvider(
          apiKey: 'fake-openai-key',
          endpoint: Uri.parse('http://example.test/v1/responses'),
        ),
        throwsArgumentError,
      );
    });

    test('lowers request and preserves streamed/completed authority', () async {
      late Map<String, Object?> captured;
      final _FakeServer server = await _FakeServer.start((request) async {
        expect(request.uri.path, '/v1/responses');
        expect(request.method, 'POST');
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer fake-openai-key',
        );
        captured = await _jsonBody(request);
        final HttpResponse response = request.response;
        response.statusCode = HttpStatus.ok;
        response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        response.headers.set('x-request-id', 'req_test');
        response.write(': comment\r\n');
        response.write('event: ignored\r\n');
        response.write('data: {"type":"response.output_text.delta",\r\n');
        response.write('data: "delta":" "}\r\n\r\n');
        _sse(response, _outputDone(_message('msg_1', 'authoritative')));
        _sse(response, _completed('resp_1'));
        await response.close();
      });
      addTearDown(server.close);
      final OpenAiModelProvider provider = OpenAiModelProvider(
        apiKey: 'fake-openai-key',
        endpoint: server.responsesUri,
      );
      addTearDown(provider.close);
      final List<ModelProviderEvent> events = await provider
          .invoke(_request(maxOutputTokens: 42))
          .toList();

      expect(captured['model'], 'test-model');
      expect(captured['instructions'], 'Follow test instructions.');
      expect(captured['store'], isFalse);
      expect(captured['stream'], isTrue);
      expect(captured['max_output_tokens'], 42);
      expect(captured['tool_choice'], 'auto');
      expect(captured['parallel_tool_calls'], isFalse);
      expect(captured['include'], <Object?>['reasoning.encrypted_content']);
      expect(captured['tools'], <Object?>[
        <String, Object?>{
          'type': 'function',
          'name': 'inspect_resource',
          'description': 'Inspect a resource.',
          'parameters': <String, Object?>{'type': 'object'},
        },
      ]);
      expect(captured['input'], <Object?>[
        <String, Object?>{
          'type': 'message',
          'role': 'user',
          'content': <Object?>[
            <String, Object?>{'type': 'input_text', 'text': 'Inspect this.'},
          ],
        },
      ]);
      expect(events, hasLength(3));
      expect(events[0].observation?.textDelta, ' ');
      expect(events[1].output?.text, 'authoritative');
      expect(events[1].output?.itemId, 'msg_1');
      expect(events[2].terminal?.settlement, ModelProviderSettlement.completed);
      expect(events[2].terminal?.responseId, 'resp_1');
      expect(events[2].terminal?.requestId, 'req_test');
      expect(events[2].terminal?.usage?.inputTokens, 11);
      expect(events[2].terminal?.usage?.outputTokens, 7);
      expect(events[2].terminal?.usage?.cacheReadTokens, 3);
      expect(events[2].terminal?.usage?.providerDetails['reasoningTokens'], 2);
    });

    test(
      'preserves native/text/tool order and exact continuation replay',
      () async {
        final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
        final _FakeServer server = await _FakeServer.start((request) async {
          requests.add(await _jsonBody(request));
          final HttpResponse response = request.response;
          response.statusCode = HttpStatus.ok;
          response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          if (requests.length == 1) {
            _sse(response, _outputDone(_reasoning('rs_a', 'enc-a')));
            _sse(response, _outputDone(_message('msg_1', 'Inspecting.')));
            _sse(response, _outputDone(_reasoning('rs_b', 'enc-b')));
            _sse(
              response,
              _outputDone(<String, Object?>{
                'type': 'function_call',
                'id': 'fc_1',
                'call_id': 'call_1',
                'name': 'inspect_resource',
                'arguments': '{"uri":"file:///tmp/test.txt"}',
                'status': 'completed',
              }),
            );
            _sse(response, _outputDone(_reasoning('rs_c', 'enc-c')));
            _sse(response, _completed('resp_1'));
          } else {
            _sse(response, _outputDone(_message('msg_2', 'Finished.')));
            _sse(response, _completed('resp_2'));
          }
          await response.close();
        });
        addTearDown(server.close);
        final OpenAiModelProvider provider = OpenAiModelProvider(
          apiKey: 'fake-openai-key',
          endpoint: server.responsesUri,
        );
        addTearDown(provider.close);
        final List<ModelProviderEvent> first = await provider
            .invoke(_request())
            .toList();
        final List<ModelProviderOutput> output = first
            .map((event) => event.output)
            .whereType<ModelProviderOutput>()
            .toList();
        expect(output.map((item) => item.kind), <ModelProviderOutputKind>[
          ModelProviderOutputKind.nativeItem,
          ModelProviderOutputKind.text,
          ModelProviderOutputKind.nativeItem,
          ModelProviderOutputKind.toolProposal,
          ModelProviderOutputKind.nativeItem,
        ]);
        expect(output[0].itemId, 'rs_a');
        expect(output[2].itemId, 'rs_b');
        expect(output[4].itemId, 'rs_c');
        expect(output[3].toolProposal?.callId, 'call_1');
        expect(output[3].toolProposal?.arguments, <String, Object?>{
          'uri': 'file:///tmp/test.txt',
        });

        final List<ModelProviderInput> replay = <ModelProviderInput>[
          _userInput(),
          for (final ModelProviderOutput item in output) _replay(item),
          ModelProviderInput(
            kind: ModelProviderInputKind.toolOutcome,
            message: null,
            toolProposal: null,
            toolOutcome: ModelProviderToolOutcome(
              callId: 'call_1',
              status: ModelProviderToolOutcomeStatus.success,
              content: 'Local inspection result.',
            ),
            itemId: null,
            nativeMetadata: null,
          ),
        ];
        final List<ModelProviderEvent> second = await provider
            .invoke(_request(input: replay))
            .toList();
        expect(
          second.last.terminal?.settlement,
          ModelProviderSettlement.completed,
        );
        final List<Object?> input = requests[1]['input']! as List<Object?>;
        expect(
          input.map((item) => (item! as Map<String, Object?>)['type']),
          <String>[
            'message',
            'reasoning',
            'message',
            'reasoning',
            'function_call',
            'reasoning',
            'function_call_output',
          ],
        );
        expect(input[1], _reasoning('rs_a', 'enc-a'));
        expect(input[3], _reasoning('rs_b', 'enc-b'));
        expect(input[5], _reasoning('rs_c', 'enc-c'));
        expect(input[4], <String, Object?>{
          'type': 'function_call',
          'id': 'fc_1',
          'call_id': 'call_1',
          'name': 'inspect_resource',
          'arguments': '{"uri":"file:///tmp/test.txt"}',
          'status': 'completed',
        });
        expect(input[2], <String, Object?>{
          'type': 'message',
          'role': 'assistant',
          'content': <Object?>[
            <String, Object?>{
              'type': 'output_text',
              'text': 'Inspecting.',
              'annotations': <Object?>[],
            },
          ],
          'id': 'msg_1',
          'status': 'completed',
        });
        expect(input[6], <String, Object?>{
          'type': 'function_call_output',
          'call_id': 'call_1',
          'output': 'Local inspection result.',
        });
      },
    );

    test('keeps consecutive native items distinct', () async {
      final _FakeServer server = await _FakeServer.start((request) async {
        await request.drain<void>();
        _sse(request.response, _outputDone(_reasoning('rs_1', 'a')));
        _sse(request.response, _outputDone(_reasoning('rs_2', 'b')));
        _sse(request.response, _completed('resp_native'));
        await request.response.close();
      });
      addTearDown(server.close);
      final OpenAiModelProvider provider = OpenAiModelProvider(
        apiKey: 'fake-openai-key',
        endpoint: server.responsesUri,
      );
      addTearDown(provider.close);
      final List<ModelProviderEvent> events = await provider
          .invoke(_request())
          .toList();
      expect(
        events.map((event) => event.output?.itemId).whereType<String>(),
        <String>['rs_1', 'rs_2'],
      );
    });

    for (final (String arguments, bool valid) in <(String, bool)>[
      ('{"value":1}', true),
      ('{"value":', false),
      ('[1,2]', false),
    ]) {
      test('classifies function arguments $arguments', () async {
        final _FakeServer server = await _FakeServer.start((request) async {
          await request.drain<void>();
          _sse(
            request.response,
            _outputDone(<String, Object?>{
              'type': 'function_call',
              'id': 'fc_args',
              'call_id': 'call_args',
              'name': 'inspect_resource',
              'arguments': arguments,
            }),
          );
          if (valid) _sse(request.response, _completed('resp_args'));
          await request.response.close();
        });
        addTearDown(server.close);
        final OpenAiModelProvider provider = OpenAiModelProvider(
          apiKey: 'fake-openai-key',
          endpoint: server.responsesUri,
        );
        addTearDown(provider.close);
        final List<ModelProviderEvent> events = await provider
            .invoke(_request())
            .toList();
        if (valid) {
          expect(
            events.first.output?.toolProposal?.arguments,
            <String, Object?>{'value': 1},
          );
        } else {
          expect(
            events.last.terminal?.failure?.kind,
            ModelProviderFailureKind.malformedResponse,
          );
        }
      });
    }

    test('maps refusal and incomplete settlements', () async {
      var requestCount = 0;
      final _FakeServer server = await _FakeServer.start((request) async {
        requestCount++;
        await request.drain<void>();
        if (requestCount == 1) {
          _sse(request.response, _outputDone(_refusal('msg_refuse', 'No.')));
          _sse(request.response, _completed('resp_refuse'));
        } else {
          _sse(request.response, <String, Object?>{
            'type': 'response.incomplete',
            'response': _response(
              'resp_incomplete',
              extra: <String, Object?>{
                'incomplete_details': <String, Object?>{
                  'reason': requestCount == 2
                      ? 'max_output_tokens'
                      : 'content_filter',
                },
              },
            ),
          });
        }
        await request.response.close();
      });
      addTearDown(server.close);
      final OpenAiModelProvider provider = OpenAiModelProvider(
        apiKey: 'fake-openai-key',
        endpoint: server.responsesUri,
      );
      addTearDown(provider.close);
      final List<ModelProviderEvent> refusal = await provider
          .invoke(_request())
          .toList();
      expect(refusal.first.output?.text, 'No.');
      expect(
        refusal.last.terminal?.settlement,
        ModelProviderSettlement.refused,
      );
      final ModelProviderTerminal outputLimit =
          (await provider.invoke(_request()).toList()).single.terminal!;
      expect(
        outputLimit.incompleteReason,
        ModelProviderIncompleteReason.outputLimit,
      );
      final ModelProviderTerminal other =
          (await provider.invoke(_request()).toList()).single.terminal!;
      expect(other.incompleteReason, ModelProviderIncompleteReason.other);
      expect(other.providerStopReason, 'content_filter');
    });

    test('keeps refusal sticky across later assistant output', () async {
      final _FakeServer server = await _FakeServer.start((request) async {
        await request.drain<void>();
        _sse(request.response, _outputDone(_refusal('msg_refuse', 'No.')));
        _sse(
          request.response,
          _outputDone(_message('msg_text', 'Explanation.')),
        );
        _sse(request.response, _completed('resp_refuse'));
        await request.response.close();
      });
      addTearDown(server.close);
      final OpenAiModelProvider provider = OpenAiModelProvider(
        apiKey: 'fake-openai-key',
        endpoint: server.responsesUri,
      );
      addTearDown(provider.close);

      final List<ModelProviderEvent> events = await provider
          .invoke(_request())
          .toList();

      expect(
        events.map((event) => event.output?.text).whereType<String>(),
        <String>['No.', 'Explanation.'],
      );
      expect(events.last.terminal?.settlement, ModelProviderSettlement.refused);
    });

    test('classifies invalid UTF-8 as malformed response', () async {
      final _FakeServer server = await _FakeServer.start((request) async {
        await request.drain<void>();
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.add(<int>[0xc3, 0x28]);
        await request.response.close();
      });
      addTearDown(server.close);
      final OpenAiModelProvider provider = OpenAiModelProvider(
        apiKey: 'fake-openai-key',
        endpoint: server.responsesUri,
      );
      addTearDown(provider.close);

      final ModelProviderTerminal terminal =
          (await provider.invoke(_request()).toList()).single.terminal!;

      expect(
        terminal.failure?.kind,
        ModelProviderFailureKind.malformedResponse,
      );
      expect(terminal.failure?.providerCode, 'invalid_utf8');
    });

    for (final (String name, Map<String, Object?> part, String code)
        in <(String, Map<String, Object?>, String)>[
          (
            'missing annotations',
            <String, Object?>{'type': 'output_text', 'text': 'Text.'},
            'invalid_output_text_annotations',
          ),
          (
            'malformed annotations',
            <String, Object?>{
              'type': 'output_text',
              'text': 'Text.',
              'annotations': 'invalid',
            },
            'invalid_output_text_annotations',
          ),
          (
            'nonempty annotations',
            <String, Object?>{
              'type': 'output_text',
              'text': 'Text.',
              'annotations': <Object?>[
                <String, Object?>{
                  'type': 'url_citation',
                  'url': 'https://example.test',
                },
              ],
            },
            'unsupported_output_text_annotations',
          ),
        ]) {
      test('rejects $name in completed output text', () async {
        final _FakeServer server = await _FakeServer.start((request) async {
          await request.drain<void>();
          _sse(
            request.response,
            _outputDone(<String, Object?>{
              'type': 'message',
              'id': 'msg_annotations',
              'role': 'assistant',
              'status': 'completed',
              'content': <Object?>[part],
            }),
          );
          await request.response.close();
        });
        addTearDown(server.close);
        final OpenAiModelProvider provider = OpenAiModelProvider(
          apiKey: 'fake-openai-key',
          endpoint: server.responsesUri,
        );
        addTearDown(provider.close);

        final ModelProviderTerminal terminal =
            (await provider.invoke(_request()).toList()).single.terminal!;

        expect(
          terminal.failure?.kind,
          ModelProviderFailureKind.malformedResponse,
        );
        expect(terminal.failure?.providerCode, code);
      });
    }

    for (final (int status, ModelProviderFailureKind kind)
        in <(int, ModelProviderFailureKind)>[
          (400, ModelProviderFailureKind.invalidRequest),
          (401, ModelProviderFailureKind.authentication),
          (403, ModelProviderFailureKind.permission),
          (429, ModelProviderFailureKind.rateLimited),
          (503, ModelProviderFailureKind.unavailable),
        ]) {
      test('maps HTTP $status without leaking headers', () async {
        final _FakeServer server = await _FakeServer.start((request) async {
          await request.drain<void>();
          request.response.statusCode = status;
          request.response.headers.set('x-request-id', 'req_failure');
          request.response.headers.set(HttpHeaders.retryAfterHeader, '3');
          request.response.write(
            jsonEncode(<String, Object?>{
              'error': <String, Object?>{
                'code': 'safe_code',
                'message': 'Safe provider message.',
              },
            }),
          );
          await request.response.close();
        });
        addTearDown(server.close);
        final OpenAiModelProvider provider = OpenAiModelProvider(
          apiKey: 'fake-openai-key',
          endpoint: server.responsesUri,
        );
        addTearDown(provider.close);
        final ModelProviderTerminal terminal =
            (await provider.invoke(_request()).toList()).single.terminal!;
        expect(terminal.failure?.kind, kind);
        expect(terminal.failure?.providerCode, 'safe_code');
        expect(terminal.failure?.providerMessage, 'Safe provider message.');
        expect(terminal.failure?.providerDetails, <String, Object?>{
          'status': status,
          'requestId': 'req_failure',
          'retryAfter': '3',
        });
        expect(terminal.failure.toString(), isNot(contains('fake-openai-key')));
      });
    }

    test('settles exactly capped HTTP error without waiting for EOF', () async {
      final _OpenErrorServer fixture = await _OpenErrorServer.start(
        initialBytes: 16 * 1024,
      );
      addTearDown(fixture.close);
      final OpenAiModelProvider provider = OpenAiModelProvider(
        apiKey: 'fake-openai-key',
        endpoint: fixture.server.responsesUri,
      );
      addTearDown(provider.close);

      final ModelProviderTerminal terminal =
          (await provider
                  .invoke(_request())
                  .toList()
                  .timeout(const Duration(seconds: 2)))
              .single
              .terminal!;

      expect(terminal.failure?.kind, ModelProviderFailureKind.unavailable);
      expect(
        terminal.failure?.providerDetails['responseBodyTruncated'],
        isTrue,
      );
      expect(fixture.writes, lessThan(40));
    });

    test('settles oversized HTTP error without waiting for EOF', () async {
      var serverWrites = 0;
      final _FakeServer server = await _FakeServer.start((request) async {
        await request.drain<void>();
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write('x' * (17 * 1024));
        await request.response.flush();
        try {
          while (true) {
            request.response.write('x' * 1024);
            await request.response.flush();
            serverWrites++;
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        } on Object {
          // Cancellation is the expected server-side settlement.
        }
      });
      addTearDown(server.close);
      final OpenAiModelProvider provider = OpenAiModelProvider(
        apiKey: 'fake-openai-key',
        endpoint: server.responsesUri,
      );
      addTearDown(provider.close);

      final ModelProviderTerminal terminal =
          (await provider
                  .invoke(_request())
                  .toList()
                  .timeout(const Duration(seconds: 2)))
              .single
              .terminal!;

      expect(terminal.failure?.kind, ModelProviderFailureKind.unavailable);
      expect(
        terminal.failure?.providerDetails['responseBodyTruncated'],
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final int writesAfterSettlement = serverWrites;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(serverWrites, writesAfterSettlement);
    });

    test('consumer cancellation stops an open non-2xx body reader', () async {
      final _OpenErrorServer fixture = await _OpenErrorServer.start(
        initialBytes: 1024,
      );
      addTearDown(fixture.close);
      final OpenAiModelProvider provider = OpenAiModelProvider(
        apiKey: 'fake-openai-key',
        endpoint: fixture.server.responsesUri,
      );
      addTearDown(provider.close);
      final StreamSubscription<ModelProviderEvent> subscription = provider
          .invoke(_request())
          .listen((_) {});
      await fixture.started.future.timeout(const Duration(seconds: 2));

      await subscription.cancel().timeout(const Duration(seconds: 2));

      await fixture.expectConsumptionStopped();
    });

    for (final (String name, Future<void> Function(HttpRequest) serve)
        in <(String, Future<void> Function(HttpRequest))>[
          (
            'malformed JSON',
            (request) async {
              request.response.write('data: {nope}\n\n');
              await request.response.close();
            },
          ),
          (
            'unterminated SSE',
            (request) async {
              request.response.write('data: {"type":"response.created"}\n');
              await request.response.close();
            },
          ),
          (
            'invalid output shape',
            (request) async {
              _sse(request.response, <String, Object?>{
                'type': 'response.output_item.done',
                'item': <String, Object?>{'type': 'function_call'},
              });
              await request.response.close();
            },
          ),
          (
            'EOF before terminal',
            (request) async {
              _sse(request.response, <String, Object?>{
                'type': 'response.created',
                'response': _response('resp_eof'),
              });
              await request.response.close();
            },
          ),
        ]) {
      test('$name is malformed response failure', () async {
        final _FakeServer server = await _FakeServer.start((request) async {
          await request.drain<void>();
          await serve(request);
        });
        addTearDown(server.close);
        final OpenAiModelProvider provider = OpenAiModelProvider(
          apiKey: 'fake-openai-key',
          endpoint: server.responsesUri,
        );
        addTearDown(provider.close);
        final List<ModelProviderEvent> events = await provider
            .invoke(_request())
            .toList();
        expect(
          events.last.terminal?.settlement,
          ModelProviderSettlement.failed,
        );
        expect(
          events.last.terminal?.failure?.kind,
          ModelProviderFailureKind.malformedResponse,
        );
      });
    }

    test('cancellation releases an open outbound response', () async {
      final Completer<void> connected = Completer<void>();
      var serverWrites = 0;
      final _FakeServer server = await _FakeServer.start((request) async {
        await request.drain<void>();
        final Socket socket = await request.response.detachSocket();
        socket.add(
          utf8.encode(
            'HTTP/1.1 200 OK\r\n'
            'Content-Type: text/event-stream\r\n'
            'Connection: close\r\n\r\n'
            'data: {"type":"response.in_progress","response":{"id":"resp_open"}}\n\n',
          ),
        );
        await socket.flush();
        connected.complete();
        try {
          while (true) {
            serverWrites++;
            socket.add(utf8.encode(': keepalive\n\n'));
            await socket.flush();
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        } on Object {
          await socket.close();
        }
      });
      addTearDown(server.close);
      final OpenAiModelProvider provider = OpenAiModelProvider(
        apiKey: 'fake-openai-key',
        endpoint: server.responsesUri,
      );
      addTearDown(provider.close);
      final StreamSubscription<ModelProviderEvent> subscription = provider
          .invoke(_request())
          .listen((_) {});
      await connected.future.timeout(const Duration(seconds: 2));
      await subscription.cancel().timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final int afterCancellation = serverWrites;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(serverWrites, afterCancellation);
    });

    test(
      'rejects provider options and incompatible native replay semantically',
      () async {
        final OpenAiModelProvider provider = OpenAiModelProvider(
          apiKey: 'fake-openai-key',
          endpoint: Uri.parse('http://127.0.0.1:1/v1/responses'),
        );
        addTearDown(provider.close);
        final ModelProviderTerminal options =
            (await provider
                    .invoke(
                      _request(providerOptions: <String, Object?>{'x': true}),
                    )
                    .toList())
                .single
                .terminal!;
        expect(
          options.failure?.kind,
          ModelProviderFailureKind.unsupportedRequest,
        );
        final ModelProviderTerminal native =
            (await provider
                    .invoke(
                      _request(
                        input: <ModelProviderInput>[
                          _userInput(),
                          ModelProviderInput(
                            kind: ModelProviderInputKind.nativeItem,
                            message: null,
                            toolProposal: null,
                            toolOutcome: null,
                            itemId: 'rs_bad',
                            nativeMetadata: ModelProviderNativeEnvelope(
                              kind: 'someone.else',
                              compatibility: const <String, Object?>{},
                              data: const <String, Object?>{},
                            ),
                          ),
                        ],
                      ),
                    )
                    .toList())
                .single
                .terminal!;
        expect(native.failure?.kind, ModelProviderFailureKind.invalidRequest);
      },
    );

    test(
      'ChatGPT profile binds OAuth account headers and request policy',
      () async {
        late HttpRequest capturedRequest;
        final _FakeServer server = await _FakeServer.start((request) async {
          capturedRequest = request;
          await request.drain<void>();
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          _sse(request.response, _outputDone(_message('msg_chatgpt', 'ready')));
          _sse(request.response, _completed('resp_chatgpt'));
          await request.response.close();
        });
        addTearDown(server.close);
        final InMemoryOpenAiCredentialStore store =
            InMemoryOpenAiCredentialStore();
        final OpenAiOAuthClient oauth = _oauth(server);
        addTearDown(oauth.close);
        final OpenAiChatGptAuth auth = OpenAiChatGptAuth(
          instanceId: 'personal',
          store: store,
          oauth: oauth,
        );
        await auth.install(
          OpenAiChatGptCredential(
            idToken: _idToken('account-personal', fedRamp: true),
            accessToken: 'oauth-access-only',
            refreshToken: 'oauth-refresh-only',
            accountId: 'account-personal',
            fedRamp: true,
            expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
          ),
        );
        final OpenAiModelProvider provider = OpenAiModelProvider.chatGpt(
          auth: auth,
          endpoint: server.responsesUri,
        );
        addTearDown(provider.close);

        final List<ModelProviderEvent> events = await provider
            .invoke(_request())
            .toList();
        expect(
          events.last.terminal?.settlement,
          ModelProviderSettlement.completed,
        );
        expect(
          capturedRequest.headers.value(HttpHeaders.authorizationHeader),
          'Bearer oauth-access-only',
        );
        expect(
          capturedRequest.headers.value('ChatGPT-Account-ID'),
          'account-personal',
        );
        expect(capturedRequest.headers.value('X-OpenAI-Fedramp'), 'true');
        expect(capturedRequest.headers.value('originator'), isNull);
        expect(capturedRequest.headers.value('x-codex-turn-state'), isNull);

        final ModelProviderTerminal unsupported =
            (await provider.invoke(_request(maxOutputTokens: 10)).toList())
                .single
                .terminal!;
        expect(
          unsupported.failure?.kind,
          ModelProviderFailureKind.unsupportedRequest,
        );
        expect(
          unsupported.failure?.providerCode,
          'chatgpt_max_output_tokens_unsupported',
        );
      },
    );

    test('ChatGPT retries one pre-output 401 after fenced refresh', () async {
      var responseRequests = 0;
      var refreshRequests = 0;
      final _FakeServer server = await _FakeServer.start((request) async {
        if (request.uri.path == '/oauth/token') {
          refreshRequests++;
          final Map<String, Object?> body = await _jsonBody(request);
          expect(body['refresh_token'], 'refresh-before');
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, Object?>{
              'id_token': _idToken('account-retry'),
              'access_token': 'access-after',
              'refresh_token': 'refresh-after',
            }),
          );
          await request.response.close();
          return;
        }
        responseRequests++;
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          responseRequests == 1
              ? 'Bearer access-before'
              : 'Bearer access-after',
        );
        await request.drain<void>();
        if (responseRequests == 1) {
          request.response.statusCode = HttpStatus.unauthorized;
          request.response.write('{"error":{"code":"expired_token"}}');
        } else {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          _sse(
            request.response,
            _outputDone(_message('msg_retry', 'recovered')),
          );
          _sse(request.response, _completed('resp_retry'));
        }
        await request.response.close();
      });
      addTearDown(server.close);
      final InMemoryOpenAiCredentialStore store =
          InMemoryOpenAiCredentialStore();
      final OpenAiOAuthClient oauth = _oauth(server);
      addTearDown(oauth.close);
      final OpenAiChatGptAuth auth = OpenAiChatGptAuth(
        instanceId: 'retry',
        store: store,
        oauth: oauth,
      );
      await auth.install(
        OpenAiChatGptCredential(
          idToken: _idToken('account-retry'),
          accessToken: 'access-before',
          refreshToken: 'refresh-before',
          accountId: 'account-retry',
          fedRamp: false,
          expiresAt: null,
        ),
      );
      final OpenAiModelProvider provider = OpenAiModelProvider.chatGpt(
        auth: auth,
        endpoint: server.responsesUri,
      );
      addTearDown(provider.close);

      final List<ModelProviderEvent> events = await provider
          .invoke(_request())
          .toList();
      expect(events.map((ModelProviderEvent event) => event.kind), <Object?>[
        ModelProviderEventKind.output,
        ModelProviderEventKind.terminal,
      ]);
      expect(events.first.output?.text, 'recovered');
      expect(responseRequests, 2);
      expect(refreshRequests, 1);
      expect(
        (await store.load('retry')).credential?.refreshToken,
        'refresh-after',
      );
    });

    test('staggered concurrent ChatGPT 401s refresh only once', () async {
      final Completer<void> firstOldArrived = Completer<void>();
      final Completer<void> secondOldArrived = Completer<void>();
      final Completer<void> releaseFirst401 = Completer<void>();
      final Completer<void> releaseSecond401 = Completer<void>();
      var oldTokenRequests = 0;
      var refreshedTokenRequests = 0;
      var refreshRequests = 0;
      final _FakeServer server = await _FakeServer.start((request) async {
        if (request.uri.path == '/oauth/token') {
          refreshRequests++;
          expect((await _jsonBody(request))['refresh_token'], 'refresh-old');
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, Object?>{
              'access_token': 'access-current',
              'refresh_token': 'refresh-current',
            }),
          );
          await request.response.close();
          return;
        }
        await request.drain<void>();
        final String? authorization = request.headers.value(
          HttpHeaders.authorizationHeader,
        );
        if (authorization == 'Bearer access-old') {
          oldTokenRequests++;
          if (oldTokenRequests == 1) {
            firstOldArrived.complete();
            await releaseFirst401.future;
          } else {
            secondOldArrived.complete();
            await releaseSecond401.future;
          }
          request.response.statusCode = HttpStatus.unauthorized;
          await request.response.close();
          return;
        }
        expect(authorization, 'Bearer access-current');
        refreshedTokenRequests++;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        _sse(
          request.response,
          _outputDone(
            _message('msg-staggered-$refreshedTokenRequests', 'recovered'),
          ),
        );
        _sse(
          request.response,
          _completed('resp-staggered-$refreshedTokenRequests'),
        );
        await request.response.close();
      });
      addTearDown(server.close);
      final InMemoryOpenAiCredentialStore store =
          InMemoryOpenAiCredentialStore();
      final OpenAiOAuthClient oauth = _oauth(server);
      addTearDown(oauth.close);
      final OpenAiChatGptAuth auth = OpenAiChatGptAuth(
        instanceId: 'staggered-401',
        store: store,
        oauth: oauth,
      );
      await auth.install(
        OpenAiChatGptCredential(
          idToken: _idToken('account-staggered'),
          accessToken: 'access-old',
          refreshToken: 'refresh-old',
          accountId: 'account-staggered',
          fedRamp: false,
          expiresAt: null,
        ),
      );
      final OpenAiModelProvider provider = OpenAiModelProvider.chatGpt(
        auth: auth,
        endpoint: server.responsesUri,
      );
      addTearDown(provider.close);

      final Future<List<ModelProviderEvent>> first = provider
          .invoke(_request())
          .toList();
      final Future<List<ModelProviderEvent>> second = provider
          .invoke(_request())
          .toList();
      await Future.wait(<Future<void>>[
        firstOldArrived.future,
        secondOldArrived.future,
      ]);
      releaseFirst401.complete();
      while ((await store.load('staggered-401')).revision == 1) {
        await Future<void>.delayed(Duration.zero);
      }
      releaseSecond401.complete();
      final List<List<ModelProviderEvent>> results = await Future.wait(
        <Future<List<ModelProviderEvent>>>[first, second],
      );

      expect(
        results.map((events) => events.last.terminal?.settlement),
        everyElement(ModelProviderSettlement.completed),
      );
      expect(oldTokenRequests, 2);
      expect(refreshedTokenRequests, 2);
      expect(refreshRequests, 1);
      expect((await store.load('staggered-401')).revision, 2);
    });

    test(
      'ChatGPT profile reuses ordered native and tool continuation',
      () async {
        final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
        final _FakeServer server = await _FakeServer.start((request) async {
          requests.add(await _jsonBody(request));
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          if (requests.length == 1) {
            _sse(
              request.response,
              _outputDone(_reasoning('rs_chat', 'enc-chat')),
            );
            _sse(
              request.response,
              _outputDone(_message('msg_chat', 'Inspect.')),
            );
            _sse(
              request.response,
              _outputDone(<String, Object?>{
                'type': 'function_call',
                'id': 'fc_chat',
                'call_id': 'call_chat',
                'name': 'inspect_resource',
                'arguments': '{"uri":"file:///tmp/chat.txt"}',
                'status': 'completed',
              }),
            );
            _sse(request.response, _completed('resp_chat_1'));
          } else {
            _sse(request.response, _outputDone(_message('msg_done', 'Done.')));
            _sse(request.response, _completed('resp_chat_2'));
          }
          await request.response.close();
        });
        addTearDown(server.close);
        final InMemoryOpenAiCredentialStore store =
            InMemoryOpenAiCredentialStore();
        final OpenAiOAuthClient oauth = _oauth(server);
        addTearDown(oauth.close);
        final OpenAiChatGptAuth auth = OpenAiChatGptAuth(
          instanceId: 'semantics',
          store: store,
          oauth: oauth,
        );
        await auth.install(
          OpenAiChatGptCredential(
            idToken: _idToken('account-semantics'),
            accessToken: 'access-semantics',
            refreshToken: 'refresh-semantics',
            accountId: 'account-semantics',
            fedRamp: false,
            expiresAt: null,
          ),
        );
        final OpenAiModelProvider provider = OpenAiModelProvider.chatGpt(
          auth: auth,
          endpoint: server.responsesUri,
        );
        addTearDown(provider.close);

        final List<ModelProviderOutput> first =
            (await provider.invoke(_request()).toList())
                .map((ModelProviderEvent event) => event.output)
                .whereType<ModelProviderOutput>()
                .toList();
        final List<ModelProviderInput> continuation = <ModelProviderInput>[
          _userInput(),
          for (final ModelProviderOutput output in first) _replay(output),
          ModelProviderInput(
            kind: ModelProviderInputKind.toolOutcome,
            message: null,
            toolProposal: null,
            toolOutcome: ModelProviderToolOutcome(
              callId: 'call_chat',
              status: ModelProviderToolOutcomeStatus.success,
              content: 'chat result',
            ),
            itemId: null,
            nativeMetadata: null,
          ),
        ];
        final List<ModelProviderEvent> second = await provider
            .invoke(_request(input: continuation))
            .toList();
        expect(
          second.last.terminal?.settlement,
          ModelProviderSettlement.completed,
        );
        expect(
          (requests[1]['input']! as List<Object?>).map(
            (Object? item) => (item! as Map<String, Object?>)['type'],
          ),
          <String>[
            'message',
            'reasoning',
            'message',
            'function_call',
            'function_call_output',
          ],
        );
        expect(
          (requests[1]['input']! as List<Object?>)[1],
          _reasoning('rs_chat', 'enc-chat'),
        );
      },
    );

    test('ChatGPT does not auth-retry after an ADELE event', () async {
      var responseRequests = 0;
      var refreshRequests = 0;
      final _FakeServer server = await _FakeServer.start((request) async {
        if (request.uri.path == '/oauth/token') {
          refreshRequests++;
          await request.drain<void>();
          request.response.write('{}');
        } else {
          responseRequests++;
          await request.drain<void>();
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          _sse(request.response, <String, Object?>{
            'type': 'response.output_text.delta',
            'delta': 'visible',
          });
          _sse(request.response, <String, Object?>{
            'type': 'error',
            'code': 'unauthorized',
            'message': 'Authentication expired.',
          });
        }
        await request.response.close();
      });
      addTearDown(server.close);
      final InMemoryOpenAiCredentialStore store =
          InMemoryOpenAiCredentialStore();
      final OpenAiOAuthClient oauth = _oauth(server);
      addTearDown(oauth.close);
      final OpenAiChatGptAuth auth = OpenAiChatGptAuth(
        instanceId: 'post-event',
        store: store,
        oauth: oauth,
      );
      await auth.install(
        OpenAiChatGptCredential(
          idToken: _idToken('account-post-event'),
          accessToken: 'access-post-event',
          refreshToken: 'refresh-post-event',
          accountId: 'account-post-event',
          fedRamp: false,
          expiresAt: null,
        ),
      );
      final OpenAiModelProvider provider = OpenAiModelProvider.chatGpt(
        auth: auth,
        endpoint: server.responsesUri,
      );
      addTearDown(provider.close);

      final List<ModelProviderEvent> events = await provider
          .invoke(_request())
          .toList();
      expect(events.first.observation?.textDelta, 'visible');
      expect(events.last.terminal?.settlement, ModelProviderSettlement.failed);
      expect(responseRequests, 1);
      expect(refreshRequests, 0);
    });

    test(
      'cancellation during ChatGPT refresh suppresses retry and events',
      () async {
        final Completer<void> refreshStarted = Completer<void>();
        final Completer<void> releaseRefresh = Completer<void>();
        var responseRequests = 0;
        final _FakeServer server = await _FakeServer.start((request) async {
          if (request.uri.path == '/oauth/token') {
            await request.drain<void>();
            refreshStarted.complete();
            await releaseRefresh.future;
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode(<String, Object?>{
                'access_token': 'access-after-cancel',
              }),
            );
          } else {
            responseRequests++;
            await request.drain<void>();
            request.response.statusCode = HttpStatus.unauthorized;
          }
          await request.response.close();
        });
        addTearDown(server.close);
        final InMemoryOpenAiCredentialStore store =
            InMemoryOpenAiCredentialStore();
        final OpenAiOAuthClient oauth = _oauth(server);
        addTearDown(oauth.close);
        final OpenAiChatGptAuth auth = OpenAiChatGptAuth(
          instanceId: 'cancel-refresh',
          store: store,
          oauth: oauth,
        );
        await auth.install(
          OpenAiChatGptCredential(
            idToken: _idToken('account-cancel'),
            accessToken: 'access-before-cancel',
            refreshToken: 'refresh-cancel',
            accountId: 'account-cancel',
            fedRamp: false,
            expiresAt: null,
          ),
        );
        final OpenAiModelProvider provider = OpenAiModelProvider.chatGpt(
          auth: auth,
          endpoint: server.responsesUri,
        );
        addTearDown(provider.close);
        final List<ModelProviderEvent> events = <ModelProviderEvent>[];
        final StreamSubscription<ModelProviderEvent> subscription = provider
            .invoke(_request())
            .listen(events.add);
        await refreshStarted.future;
        await subscription.cancel();
        releaseRefresh.complete();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(events, isEmpty);
        expect(responseRequests, 1);
      },
    );

    test('persistent ChatGPT 401 performs no retry loop', () async {
      var responseRequests = 0;
      var refreshRequests = 0;
      final _FakeServer server = await _FakeServer.start((request) async {
        if (request.uri.path == '/oauth/token') {
          refreshRequests++;
          await request.drain<void>();
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, Object?>{'access_token': 'still-invalid'}),
          );
        } else {
          responseRequests++;
          await request.drain<void>();
          request.response.statusCode = HttpStatus.unauthorized;
        }
        await request.response.close();
      });
      addTearDown(server.close);
      final InMemoryOpenAiCredentialStore store =
          InMemoryOpenAiCredentialStore();
      final OpenAiOAuthClient oauth = _oauth(server);
      addTearDown(oauth.close);
      final OpenAiChatGptAuth auth = OpenAiChatGptAuth(
        instanceId: 'persistent-401',
        store: store,
        oauth: oauth,
      );
      await auth.install(
        OpenAiChatGptCredential(
          idToken: _idToken('account-401'),
          accessToken: 'invalid',
          refreshToken: 'refresh',
          accountId: 'account-401',
          fedRamp: false,
          expiresAt: null,
        ),
      );
      final OpenAiModelProvider provider = OpenAiModelProvider.chatGpt(
        auth: auth,
        endpoint: server.responsesUri,
      );
      addTearDown(provider.close);

      final ModelProviderTerminal terminal =
          (await provider.invoke(_request()).toList()).single.terminal!;
      expect(terminal.failure?.kind, ModelProviderFailureKind.authentication);
      expect(responseRequests, 2);
      expect(refreshRequests, 1);
    });
  });
}

ModelProviderRequest _request({
  List<ModelProviderInput>? input,
  int? maxOutputTokens,
  Map<String, Object?> providerOptions = const <String, Object?>{},
  ModelProviderToolChoice toolChoice = ModelProviderToolChoice.auto,
}) => ModelProviderRequest(
  model: 'test-model',
  instructions: 'Follow test instructions.',
  input: input ?? <ModelProviderInput>[_userInput()],
  tools: <ModelProviderTool>[
    ModelProviderTool(
      name: 'inspect_resource',
      description: 'Inspect a resource.',
      argumentsSchema: const <String, Object?>{'type': 'object'},
    ),
  ],
  toolChoice: toolChoice,
  maxOutputTokens: maxOutputTokens,
  providerOptions: providerOptions,
  nativeState: null,
);

ModelProviderInput _userInput() => ModelProviderInput(
  kind: ModelProviderInputKind.message,
  message: ModelProviderMessage(
    role: ModelProviderMessageRole.user,
    content: <ModelProviderContent>[
      ModelProviderContent(
        kind: ModelProviderContentKind.text,
        text: 'Inspect this.',
      ),
    ],
  ),
  toolProposal: null,
  toolOutcome: null,
  itemId: null,
  nativeMetadata: null,
);

ModelProviderInput _replay(ModelProviderOutput output) => switch (output.kind) {
  ModelProviderOutputKind.nativeItem => ModelProviderInput(
    kind: ModelProviderInputKind.nativeItem,
    message: null,
    toolProposal: null,
    toolOutcome: null,
    itemId: output.itemId,
    nativeMetadata: output.nativeMetadata,
  ),
  ModelProviderOutputKind.text => ModelProviderInput(
    kind: ModelProviderInputKind.message,
    message: ModelProviderMessage(
      role: ModelProviderMessageRole.assistant,
      content: <ModelProviderContent>[
        ModelProviderContent(
          kind: ModelProviderContentKind.text,
          text: output.text!,
        ),
      ],
    ),
    toolProposal: null,
    toolOutcome: null,
    itemId: output.itemId,
    nativeMetadata: output.nativeMetadata,
  ),
  ModelProviderOutputKind.toolProposal => ModelProviderInput(
    kind: ModelProviderInputKind.toolProposal,
    message: null,
    toolProposal: output.toolProposal,
    toolOutcome: null,
    itemId: output.itemId,
    nativeMetadata: output.nativeMetadata,
  ),
};

Map<String, Object?> _outputDone(Map<String, Object?> item) =>
    <String, Object?>{
      'type': 'response.output_item.done',
      'output_index': 0,
      'item': item,
    };

Map<String, Object?> _message(String id, String text) => <String, Object?>{
  'type': 'message',
  'id': id,
  'role': 'assistant',
  'status': 'completed',
  'content': <Object?>[
    <String, Object?>{
      'type': 'output_text',
      'text': text,
      'annotations': <Object?>[],
    },
  ],
};

Map<String, Object?> _refusal(String id, String text) => <String, Object?>{
  'type': 'message',
  'id': id,
  'role': 'assistant',
  'status': 'completed',
  'content': <Object?>[
    <String, Object?>{'type': 'refusal', 'refusal': text},
  ],
};

Map<String, Object?> _reasoning(String id, String encrypted) =>
    <String, Object?>{
      'type': 'reasoning',
      'id': id,
      'summary': <Object?>[],
      'encrypted_content': encrypted,
    };

Map<String, Object?> _completed(String id) => <String, Object?>{
  'type': 'response.completed',
  'response': _response(id),
};

Map<String, Object?> _response(
  String id, {
  Map<String, Object?> extra = const <String, Object?>{},
}) => <String, Object?>{
  'id': id,
  'model': 'test-model-effective',
  'usage': <String, Object?>{
    'input_tokens': 11,
    'output_tokens': 7,
    'total_tokens': 18,
    'input_tokens_details': <String, Object?>{'cached_tokens': 3},
    'output_tokens_details': <String, Object?>{'reasoning_tokens': 2},
  },
  ...extra,
};

void _sse(HttpResponse response, Map<String, Object?> event) {
  response.write('data: ${jsonEncode(event)}\n\n');
}

Future<Map<String, Object?>> _jsonBody(HttpRequest request) async {
  final Object? value = jsonDecode(await utf8.decoder.bind(request).join());
  return value! as Map<String, Object?>;
}

OpenAiOAuthClient _oauth(_FakeServer server) => OpenAiOAuthClient(
  configuration: OpenAiOAuthConfiguration(
    clientId: 'authorized-test-client',
    issuer: Uri.parse(
      'http://${server.server.address.address}:${server.server.port}',
    ),
    redirectUri: Uri.parse('http://127.0.0.1:1455/auth/callback'),
  ),
);

String _idToken(String accountId, {bool fedRamp = false}) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode(<String, Object?>{'alg': 'none'})}.${encode(<String, Object?>{
    'https://api.openai.com/auth': <String, Object?>{'chatgpt_account_id': accountId, 'chatgpt_account_is_fedramp': fedRamp},
  })}.';
}

final class _FakeServer {
  _FakeServer._(this.server, this._subscription);

  final HttpServer server;
  final StreamSubscription<HttpRequest> _subscription;

  Uri get responsesUri =>
      Uri.parse('http://${server.address.address}:${server.port}/v1/responses');

  static Future<_FakeServer> start(
    Future<void> Function(HttpRequest request) handler,
  ) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    late final StreamSubscription<HttpRequest> subscription;
    subscription = server.listen((HttpRequest request) {
      unawaited(handler(request));
    });
    return _FakeServer._(server, subscription);
  }

  Future<void> close() async {
    await _subscription.cancel();
    await server.close(force: true);
  }
}

final class _OpenErrorServer {
  _OpenErrorServer._(this.server, this.started, this._writes);

  final _FakeServer server;
  final Completer<void> started;
  final int Function() _writes;

  int get writes => _writes();

  static Future<_OpenErrorServer> start({required int initialBytes}) async {
    final Completer<void> started = Completer<void>();
    var writes = 0;
    final _FakeServer server = await _FakeServer.start((request) async {
      await request.drain<void>();
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('x' * initialBytes);
      await request.response.flush();
      started.complete();
      try {
        while (true) {
          request.response.write('x' * 256);
          await request.response.flush();
          writes++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      } on Object {
        // Reader cancellation is the expected server-side settlement.
      }
    });
    return _OpenErrorServer._(server, started, () => writes);
  }

  Future<void> expectConsumptionStopped() async {
    await Future<void>.delayed(const Duration(seconds: 1));
    final int writesAfterCleanup = _writes();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(_writes(), writesAfterCleanup);
  }

  Future<void> close() => server.close();
}
