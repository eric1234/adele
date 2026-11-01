import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:openai_model_provider_backend/openai_model_provider_backend.dart';
import 'package:openai_model_provider_backend/src/openai_chatgpt_auth.dart';
import 'package:test/test.dart';

const _deadline = Duration(seconds: 3);
const _shortTimeout = Duration(milliseconds: 30);
const _secret = 'PRIVATE-API-KEY';

void main() {
  group('OpenAI transport reliability', () {
    for (final bool exhaust in <bool>[false, true]) {
      test(
        'SSE inactivity ${exhaust ? 'exhausts one retry' : 'recovers'}',
        () async {
          final first = _Response();
          final second = exhaust ? _Response() : _success();
          final client = _Client(<_Open>[
            () => _Request(first),
            () => _Request(second),
          ]);
          final provider = _provider(client, inactivityTimeout: _shortTimeout);
          final events = await provider
              .invoke(_request())
              .toList()
              .timeout(_deadline);

          expect(client.attempts, 2);
          expect(first.cancels, 1);
          if (exhaust) {
            _expectFailure(events, code: 'sse_inactivity', cause: 'inactivity');
          } else {
            _expectCompleted(events);
          }
        },
      );

      test(
        'clean EOF ${exhaust ? 'exhausts one retry' : 'recovers'}',
        () async {
          final first = _Response()
            ..send(<String, Object?>{'type': 'keepalive'})
            ..send(<String, Object?>{'type': 'response.created'})
            ..send(<String, Object?>{'type': 'response.metadata'});
          unawaited(first.controller.close());
          final second = exhaust ? _Response() : _success();
          if (exhaust) unawaited(second.controller.close());
          final client = _Client(<_Open>[
            () => _Request(first),
            () => _Request(second),
          ]);
          final provider = _provider(client);

          final events = await provider
              .invoke(_request())
              .toList()
              .timeout(_deadline);

          expect(client.attempts, 2);
          if (exhaust) {
            _expectFailure(
              events,
              code: 'missing_terminal',
              cause: 'premature_eof',
              kind: ModelProviderFailureKind.malformedResponse,
            );
          } else {
            _expectCompleted(events);
          }
        },
      );
    }

    for (final (String cause, Object error, String code)
        in <(String, Object, String)>[
          (
            'socket',
            const SocketException(
              'PRIVATE-TRANSPORT',
              osError: OSError('PRIVATE-OS', 104),
            ),
            'network_error',
          ),
          ('http', const HttpException('PRIVATE-TRANSPORT'), 'http_transport'),
          ('tls', const HandshakeException('PRIVATE-TRANSPORT'), 'tls_error'),
          (
            'timeout',
            TimeoutException('PRIVATE-TRANSPORT'),
            'response_open_timeout',
          ),
          ('unknown', StateError('PRIVATE-TRANSPORT'), 'transport_error'),
        ]) {
      for (final stage in <String>[
        'connection',
        'request_submission',
        'response_headers',
        'sse',
        'error_body',
      ]) {
        final retryable =
            cause != 'tls' && cause != 'unknown' && stage != 'error_body';
        for (final bool exhaust in <bool>[if (retryable) false, true]) {
          test(
            '$stage $cause ${!retryable
                ? 'does not retry'
                : exhaust
                ? 'exhausts one retry'
                : 'recovers'}',
            () async {
              final client = _Client(<_Open>[
                _failedOpen(stage, error),
                if (retryable)
                  if (exhaust)
                    _failedOpen(stage, error)
                  else
                    () => _Request(_success()),
              ]);
              final provider = _provider(client);

              final events = await provider
                  .invoke(_request())
                  .toList()
                  .timeout(_deadline);

              expect(client.attempts, retryable ? 2 : 1);
              expect(client.closes, 0);
              if (exhaust) {
                _expectFailure(
                  events,
                  code: stage == 'error_body'
                      ? 'http_503'
                      : stage == 'sse'
                      ? 'stream_transport'
                      : code,
                  stage: stage,
                  cause: cause,
                  kind: stage == 'error_body'
                      ? ModelProviderFailureKind.unavailable
                      : ModelProviderFailureKind.transport,
                  attempts: retryable ? 2 : 1,
                  retries: retryable ? 1 : 0,
                  osErrorCode: cause == 'socket' ? 104 : null,
                );
                final failure = events.single.terminal!.failure!;
                expect(failure.providerMessage, isNot(contains('PRIVATE')));
                expect(
                  jsonEncode(failure.providerDetails),
                  isNot(contains('PRIVATE')),
                );
              } else {
                _expectCompleted(events);
              }
            },
          );
        }
      }
    }

    for (final (int status, ModelProviderFailureKind kind)
        in <(int, ModelProviderFailureKind)>[
          (400, ModelProviderFailureKind.invalidRequest),
          (401, ModelProviderFailureKind.authentication),
          (403, ModelProviderFailureKind.permission),
          (404, ModelProviderFailureKind.unsupportedRequest),
          (429, ModelProviderFailureKind.rateLimited),
          (503, ModelProviderFailureKind.unavailable),
        ]) {
      test('HTTP $status is not retried when error body stalls', () async {
        final response = _Response(status: status);
        final client = _Client(<_Open>[() => _Request(response)]);
        final provider = _provider(client, responseOpenTimeout: _shortTimeout);

        final events = await provider
            .invoke(_request())
            .toList()
            .timeout(_deadline);

        _expectFailure(
          events,
          code: 'http_$status',
          kind: kind,
          cause: 'timeout',
          stage: 'error_body',
          attempts: 1,
          retries: 0,
        );
        expect(client.attempts, 1);
        expect(
          events.single.terminal!.failure!.providerDetails['status'],
          status,
        );
        expect(response.cancels, 1);
      });
    }

    for (final (String label, Map<String, Object?> output)
        in <(String, Map<String, Object?>)>[
          (
            'text observation',
            <String, Object?>{
              'type': 'response.output_text.delta',
              'delta': 'Observed.',
            },
          ),
          ('text output', _textOutput()),
          (
            'native output',
            _item(<String, Object?>{
              'type': 'reasoning',
              'id': 'reasoning-1',
              'encrypted_content': 'OPAQUE',
            }),
          ),
          (
            'tool proposal',
            _item(<String, Object?>{
              'type': 'function_call',
              'id': 'tool-1',
              'call_id': 'call-1',
              'name': 'inspect',
              'arguments': '{}',
            }),
          ),
        ]) {
      for (final ending in <String>['socket', 'inactivity', 'eof']) {
        test('$label fences retry after $ending', () async {
          final response = _Response();
          final client = _Client(<_Open>[() => _Request(response)]);
          final provider = _provider(client, inactivityTimeout: _shortTimeout);
          final events = <ModelProviderEvent>[];
          final observed = Completer<void>();
          final done = Completer<void>();
          final subscription = provider.invoke(_request()).listen((event) {
            events.add(event);
            if (event.kind != ModelProviderEventKind.terminal &&
                !observed.isCompleted) {
              observed.complete();
            }
          }, onDone: done.complete);
          addTearDown(subscription.cancel);
          await response.listening.future.timeout(_deadline);
          response.send(output);
          await observed.future.timeout(_deadline);
          if (ending == 'socket') {
            response.controller.addError(const SocketException('reset'));
          } else if (ending == 'eof') {
            unawaited(response.controller.close());
          }
          await done.future.timeout(_deadline);

          expect(client.attempts, 1);
          expect(events, hasLength(2));
          expect(
            events.first.kind,
            label == 'text observation'
                ? ModelProviderEventKind.observation
                : ModelProviderEventKind.output,
          );
          _expectFailure(
            events,
            code: switch (ending) {
              'socket' => 'stream_transport',
              'inactivity' => 'sse_inactivity',
              _ => 'missing_terminal',
            },
            cause: ending == 'eof' ? 'premature_eof' : ending,
            kind: ending == 'eof'
                ? ModelProviderFailureKind.malformedResponse
                : ModelProviderFailureKind.transport,
            attempts: 1,
            retries: 0,
            published: true,
          );
        });
      }
    }

    for (final (String label, List<int> bytes, String code)
        in <(String, List<int>, String)>[
          ('invalid UTF-8', <int>[0xff, 0xfe], 'invalid_utf8'),
          (
            'invalid JSON',
            utf8.encode('data: {bad-json}\n\n'),
            'malformed_json',
          ),
          (
            'unsupported event',
            utf8.encode('data: {"type":"unknown"}\n\n'),
            'unsupported_event',
          ),
          (
            'unterminated SSE record',
            utf8.encode('data: {"type":"keepalive"}\n'),
            'unterminated_sse_event',
          ),
          (
            'DONE without terminal',
            utf8.encode('data: [DONE]\n\n'),
            'unexpected_done_sentinel',
          ),
        ]) {
      test('$label never retries', () async {
        final response = _Response()..controller.add(bytes);
        unawaited(response.controller.close());
        final client = _Client(<_Open>[() => _Request(response)]);
        final provider = _provider(client);

        final events = await provider
            .invoke(_request())
            .toList()
            .timeout(_deadline);

        expect(client.attempts, 1);
        expect(events, hasLength(1));
        expect(
          events.single.terminal!.failure!.kind,
          ModelProviderFailureKind.malformedResponse,
        );
        expect(events.single.terminal!.failure!.providerCode, code);
      });
    }

    for (final bool fragments in <bool>[false, true]) {
      test(
        '${fragments ? 'partial comment bytes' : 'keepalive records'} reset inactivity, not total duration',
        () async {
          const idle = Duration(milliseconds: 200);
          final response = _Response();
          final client = _Client(<_Open>[() => _Request(response)]);
          final provider = _provider(client, inactivityTimeout: idle);
          final result = provider.invoke(_request()).toList();
          await response.listening.future.timeout(_deadline);
          // No decoded line is available until the final chunk in the fragment case.
          for (var index = 0; index < 8; index++) {
            await Future<void>.delayed(const Duration(milliseconds: 40));
            if (fragments) {
              response.controller.add(
                utf8.encode(index == 0 ? ': comment' : ' more'),
              );
            } else {
              response.send(<String, Object?>{'type': 'keepalive'});
            }
            expect(client.attempts, 1);
            expect(response.cancels, 0);
          }
          if (fragments) response.controller.add(utf8.encode('\n\n'));
          response.complete();

          _expectCompleted(await result.timeout(_deadline));
          expect(client.attempts, 1);
        },
      );
    }

    for (final bool finish in <bool>[false, true]) {
      test(
        'pause suspends inactivity; resume ${finish ? 'completes' : 'rearms watchdog'}',
        () async {
          final response = _Response();
          final client = _Client(<_Open>[() => _Request(response)]);
          final provider = _provider(client, inactivityTimeout: _shortTimeout);
          final events = <ModelProviderEvent>[];
          final observed = Completer<void>();
          final done = Completer<void>();
          final subscription = provider.invoke(_request()).listen((event) {
            events.add(event);
            if (event.observation != null) observed.complete();
          }, onDone: done.complete);
          addTearDown(subscription.cancel);
          await response.listening.future.timeout(_deadline);
          response.send(<String, Object?>{
            'type': 'response.output_text.delta',
            'delta': 'Observed.',
          });
          await observed.future.timeout(_deadline);
          subscription.pause();
          await Future<void>.delayed(_shortTimeout * 3);

          expect(response.pauses, greaterThanOrEqualTo(1));
          expect(events, hasLength(1));
          expect(response.cancels, 0);
          expect(client.attempts, 1);
          subscription.resume();
          if (finish) response.complete();
          await done.future.timeout(_deadline);

          expect(response.resumes, greaterThanOrEqualTo(1));
          expect(events, hasLength(2));
          if (finish) {
            _expectCompleted(events);
          } else {
            _expectFailure(
              events,
              code: 'sse_inactivity',
              cause: 'inactivity',
              attempts: 1,
              retries: 0,
              published: true,
            );
          }
        },
      );
    }

    for (final bool headers in <bool>[false, true]) {
      final stage = headers ? 'response_headers' : 'connection';
      test('$stage deadline exhausts exactly one retry', () async {
        final gates = <Completer<_Request>>[];
        final responseGates = <Completer<HttpClientResponse>>[];
        FutureOr<HttpClientRequest> pending() {
          if (headers) {
            final gate = Completer<HttpClientResponse>();
            responseGates.add(gate);
            return _Request(_Response(), openResponse: () => gate.future);
          }
          final gate = Completer<_Request>();
          gates.add(gate);
          return gate.future;
        }

        final client = _Client(<_Open>[pending, pending]);
        final provider = _provider(client, responseOpenTimeout: _shortTimeout);

        final events = await provider
            .invoke(_request())
            .toList()
            .timeout(_deadline);

        expect(client.attempts, 2);
        _expectFailure(
          events,
          code: 'response_open_timeout',
          stage: stage,
          cause: 'timeout',
        );
        for (final gate in gates) {
          final late = _Request(_success());
          gate.complete(late);
          await late.aborted.future.timeout(_deadline);
          expect(late.body.toString(), isEmpty);
          expect(late.responseOpens, 0);
        }
        for (final gate in responseGates) {
          final late = _success();
          gate.complete(late);
          await late.disposed.future.timeout(_deadline);
        }
        expect(client.attempts, 2);
      });

      test('late $stage success cannot publish into retry', () async {
        final lateResponse = _success();
        final responseGate = Completer<HttpClientResponse>();
        final lateRequest = _Request(
          lateResponse,
          openResponse: headers ? () => responseGate.future : null,
        );
        final connectionGate = Completer<HttpClientRequest>();
        final retryResponse = _Response();
        final client = _Client(<_Open>[
          () => headers ? lateRequest : connectionGate.future,
          () => _Request(retryResponse),
        ]);
        final provider = _provider(client, responseOpenTimeout: _shortTimeout);
        final events = <ModelProviderEvent>[];
        final done = Completer<void>();
        final subscription = provider
            .invoke(_request())
            .listen(events.add, onDone: done.complete);
        addTearDown(subscription.cancel);
        await retryResponse.listening.future.timeout(_deadline);
        if (headers) {
          responseGate.complete(lateResponse);
          await lateResponse.disposed.future.timeout(_deadline);
        } else {
          connectionGate.complete(lateRequest);
          await lateRequest.aborted.future.timeout(_deadline);
          expect(lateRequest.body.toString(), isEmpty);
          expect(lateRequest.responseOpens, 0);
        }
        expect(events, isEmpty);
        retryResponse.complete('retry-response');
        await done.future.timeout(_deadline);

        _expectCompleted(events);
        expect(events.single.terminal!.responseId, 'retry-response');
        expect(client.attempts, 2);
      });

      test('late $stage error cannot fail the current retry', () async {
        final connectionGate = Completer<HttpClientRequest>();
        final responseGate = Completer<HttpClientResponse>();
        final retry = _Response();
        final client = _Client(<_Open>[
          () => headers
              ? _Request(_Response(), openResponse: () => responseGate.future)
              : connectionGate.future,
          () => _Request(retry),
        ]);
        final provider = _provider(client, responseOpenTimeout: _shortTimeout);
        final events = <ModelProviderEvent>[];
        final done = Completer<void>();
        final subscription = provider
            .invoke(_request())
            .listen(events.add, onDone: done.complete);
        addTearDown(subscription.cancel);
        await retry.listening.future.timeout(_deadline);
        if (headers) {
          responseGate.completeError(const SocketException('late failure'));
        } else {
          connectionGate.completeError(const SocketException('late failure'));
        }
        await Future<void>.delayed(Duration.zero);
        expect(events, isEmpty);
        retry.complete();
        await done.future.timeout(_deadline);

        _expectCompleted(events);
        expect(client.attempts, 2);
      });

      for (final bool dispose in <bool>[false, true]) {
        test(
          '${dispose ? 'provider close' : 'consumer cancellation'} fences pending $stage',
          () async {
            final connectionGate = Completer<HttpClientRequest>();
            final responseGate = Completer<HttpClientResponse>();
            final lateResponse = _success();
            final lateRequest = _Request(
              lateResponse,
              openResponse: () => responseGate.future,
            );
            final client = _Client(<_Open>[
              () => headers ? lateRequest : connectionGate.future,
            ]);
            final provider = _provider(
              client,
              responseOpenTimeout: _shortTimeout,
            );
            final events = <ModelProviderEvent>[];
            final subscription = provider.invoke(_request()).listen(events.add);
            addTearDown(subscription.cancel);
            await client.started.future.timeout(_deadline);
            if (headers) await lateRequest.opening.future.timeout(_deadline);
            if (dispose) {
              provider.close();
            } else {
              await subscription.cancel().timeout(_deadline);
            }
            if (headers) {
              responseGate.complete(lateResponse);
              await lateResponse.disposed.future.timeout(_deadline);
            } else {
              connectionGate.complete(lateRequest);
              await lateRequest.aborted.future.timeout(_deadline);
              expect(lateRequest.responseOpens, 0);
            }
            await Future<void>.delayed(_shortTimeout * 2);

            expect(client.attempts, 1);
            expect(events, isEmpty);
            expect(client.closes, 0);
          },
        );
      }
    }

    for (final bool abortFails in <bool>[false, true]) {
      test(
        '${abortFails ? 'request abort' : 'subscription cancellation'} failure cannot block retry',
        () async {
          final cleanup = Completer<void>();
          final first = _Response(
            cancelGate: abortFails ? null : cleanup.future,
          );
          final second = _Response();
          final client = _Client(<_Open>[
            () => _Request(
              first,
              abortFailure: abortFails ? StateError('PRIVATE-CLEANUP') : null,
            ),
            () => _Request(second),
          ]);
          final provider = _provider(client);
          final result = provider.invoke(_request()).toList();
          await first.listening.future.timeout(_deadline);
          first.controller.addError(const SocketException('reset'));
          await first.disposed.future.timeout(_deadline);
          if (!abortFails) cleanup.completeError(StateError('PRIVATE-CLEANUP'));
          await second.listening.future.timeout(_deadline);
          second.complete();

          _expectCompleted(await result.timeout(_deadline));
          expect(first.cancels, 1);
          expect(client.attempts, 2);
        },
      );
    }

    test('retry waits for old subscription cleanup', () async {
      final gate = Completer<void>();
      final first = _Response(cancelGate: gate.future);
      final firstRequest = _Request(first);
      final second = _Response();
      final client = _Client(<_Open>[
        () => firstRequest,
        () => _Request(second),
      ]);
      final provider = _provider(
        client,
        cleanupTimeout: const Duration(seconds: 1),
      );
      final result = provider.invoke(_request()).toList();
      await first.listening.future.timeout(_deadline);
      first.controller.addError(const SocketException('reset'));
      await first.disposed.future.timeout(_deadline);
      await Future<void>.delayed(Duration.zero);

      expect(firstRequest.aborts, 1);
      expect(client.attempts, 1);
      gate.complete();
      await second.listening.future.timeout(_deadline);
      second.complete();
      _expectCompleted(await result.timeout(_deadline));
      expect(client.attempts, 2);
    });

    test('bounded cleanup fences stale bytes before retry', () async {
      final gate = Completer<void>();
      final first = _Response(cancelGate: gate.future);
      final second = _Response();
      final client = _Client(<_Open>[
        () => _Request(first),
        () => _Request(second),
      ]);
      final provider = _provider(client, cleanupTimeout: _shortTimeout);
      final events = <ModelProviderEvent>[];
      final done = Completer<void>();
      final subscription = provider
          .invoke(_request())
          .listen(events.add, onDone: done.complete);
      addTearDown(subscription.cancel);
      await first.listening.future.timeout(_deadline);
      first.controller.addError(const SocketException('reset'));
      await second.listening.future.timeout(_deadline);
      expect(gate.isCompleted, isFalse);
      first.send(_textOutput());
      first.complete('stale-response');
      gate.complete();
      second.complete('current-response');
      await done.future.timeout(_deadline);

      _expectCompleted(events);
      expect(events, hasLength(1));
      expect(events.single.terminal!.responseId, 'current-response');
      expect(first.cancels, 1);
      expect(client.attempts, 2);
    });

    for (final bool dispose in <bool>[false, true]) {
      for (final bool duringCleanup in <bool>[false, true]) {
        test(
          '${dispose ? 'provider close' : 'consumer cancel'} fences ${duringCleanup ? 'cleanup' : 'retry delay'}',
          () async {
            const retryDelay = Duration(milliseconds: 100);
            final gate = Completer<void>();
            final first = _Response(
              cancelGate: duringCleanup ? gate.future : null,
            );
            final client = _Client(<_Open>[() => _Request(first)]);
            final provider = _provider(
              client,
              transportRetryDelay: retryDelay,
              cleanupTimeout: _shortTimeout,
            );
            final events = <ModelProviderEvent>[];
            final subscription = provider.invoke(_request()).listen(events.add);
            addTearDown(subscription.cancel);
            await first.listening.future.timeout(_deadline);
            first.controller.addError(const SocketException('reset'));
            await first.disposed.future.timeout(_deadline);
            // Let immediate cleanup settle so the delay case reaches its timer.
            if (!duringCleanup) await Future<void>.delayed(Duration.zero);
            if (dispose) {
              provider.close();
            } else {
              await subscription.cancel().timeout(_deadline);
            }
            if (duringCleanup) gate.complete();
            await Future<void>.delayed(retryDelay * 2);

            expect(client.attempts, 1);
            expect(events, isEmpty);
            expect(
              client.closes,
              0,
              reason:
                  'The injected shared client is not owned by the provider.',
            );
            expect(first.cancels, 1);
          },
        );
      }
    }

    test(
      'simultaneous invocations isolate recovery and shared client lifetime',
      () async {
        final failing = _Response();
        final healthy = _Response();
        final recovered = _Response();
        final client = _Client(<_Open>[
          () => _Request(failing),
          () => _Request(healthy),
          () => _Request(recovered),
        ]);
        final provider = _provider(client);
        final first = provider.invoke(_request()).toList();
        await failing.listening.future.timeout(_deadline);
        final second = provider.invoke(_request()).toList();
        await healthy.listening.future.timeout(_deadline);
        failing.controller.addError(const SocketException('reset'));
        await recovered.listening.future.timeout(_deadline);

        expect(healthy.cancels, 0);
        expect(client.closes, 0);
        healthy.complete('healthy-response');
        recovered.complete('recovered-response');
        final firstEvents = await first.timeout(_deadline);
        final secondEvents = await second.timeout(_deadline);
        _expectCompleted(firstEvents);
        _expectCompleted(secondEvents);
        expect(firstEvents.single.terminal!.responseId, 'recovered-response');
        expect(secondEvents.single.terminal!.responseId, 'healthy-response');
        expect(client.attempts, 3);
        provider.close();
        expect(client.closes, 0);
      },
    );

    test(
      'closing provider drains all active invocations without closing shared client',
      () async {
        final cleanup = Completer<void>();
        final responses = <_Response>[
          _Response(cancelGate: cleanup.future),
          _Response(),
        ];
        final client = _Client(<_Open>[
          for (final response in responses) () => _Request(response),
        ]);
        final provider = _provider(client);
        final results = <Future<List<ModelProviderEvent>>>[];
        for (final response in responses) {
          results.add(provider.invoke(_request()).toList());
          await response.listening.future.timeout(_deadline);
        }
        provider.close();
        for (final result in results) {
          expect(await result.timeout(_deadline), isEmpty);
        }
        expect(cleanup.isCompleted, isFalse);
        cleanup.complete();
        expect(responses.map((response) => response.cancels), everyElement(1));
        expect(client.attempts, 2);
        expect(client.closes, 0);
        final rejected = await provider
            .invoke(_request())
            .toList()
            .timeout(_deadline);
        expect(
          rejected.single.terminal!.failure!.providerCode,
          'provider_closed',
        );
        expect(client.attempts, 2);
      },
    );

    test(
      'transport diagnostics retain request ID but not endpoint or secrets',
      () async {
        final responses = List<_Response>.generate(
          2,
          (_) => _Response()
            ..headers.set('x-request-id', 'request-$_secret')
            ..controller.addError(
              SocketException(
                '$_secret PRIVATE-BODY PRIVATE-ACCOUNT PRIVATE-AFFINITY',
                address: InternetAddress.loopbackIPv4,
                port: 4444,
                osError: const OSError('PRIVATE-OS-ERROR', 104),
              ),
            ),
        );
        final client = _Client(<_Open>[
          for (final response in responses) () => _Request(response),
        ]);
        final provider = _provider(client);

        final events = await provider
            .invoke(_request())
            .toList()
            .timeout(_deadline);

        _expectFailure(
          events,
          code: 'stream_transport',
          cause: 'socket',
          osErrorCode: 104,
        );
        final terminal = events.single.terminal!;
        expect(terminal.requestId, 'request-[REDACTED]');
        final diagnostics = jsonEncode(<Object?>[
          terminal.requestId,
          terminal.failure!.providerCode,
          terminal.failure!.providerMessage,
          terminal.failure!.providerDetails,
        ]);
        for (final secret in <String>[
          _secret,
          'PRIVATE-BODY',
          'PRIVATE-ACCOUNT',
          'PRIVATE-AFFINITY',
          'PRIVATE-OS-ERROR',
          '127.0.0.1',
          '4444',
        ]) {
          expect(diagnostics, isNot(contains(secret)));
        }
      },
    );
  });

  group('OpenAI response cleanup and diagnostic regressions', () {
    for (final (String header, int status) in <(String, int)>[
      ('x-request-id', 200),
      ('x-request-id', 503),
      ('x-oai-request-id', 200),
      ('x-oai-request-id', 503),
      (HttpHeaders.retryAfterHeader, 503),
    ]) {
      test('ambiguous $header on HTTP $status cancels without retry', () async {
        final response = _Response(status: status)
          ..headers.set(header, <String>['PRIVATE-FIRST', 'PRIVATE-SECOND']);
        if (header == HttpHeaders.retryAfterHeader) {
          response.controller.add(utf8.encode('{}'));
          unawaited(response.controller.close());
        }
        final client = _Client(<_Open>[() => _Request(response)]);
        final provider = _provider(client);

        final events = await provider
            .invoke(_request())
            .toList()
            .timeout(_deadline);
        await response.disposed.future.timeout(_deadline);

        _expectFailure(
          events,
          code: 'invalid_response_headers',
          cause: 'invalid_headers',
          kind: ModelProviderFailureKind.malformedResponse,
          stage: header == HttpHeaders.retryAfterHeader
              ? 'error_body'
              : 'response_headers',
          attempts: 1,
          retries: 0,
        );
        expect(response.cancels, 1);
        expect(client.attempts, 1);
        expect(
          events.single.terminal!.failure!.providerMessage,
          isNot(contains('PRIVATE')),
        );
      });
    }

    for (final bool oversized in <bool>[false, true]) {
      test(
        'HTTP503 ${oversized ? 'oversized' : 'failed'} body contains cancellation errors',
        () async {
          final uncaught = <Object>[];
          late _Response response;
          late _Client client;
          final work = runZonedGuarded<Future<List<ModelProviderEvent>>>(
            () async {
              final cancellation = Completer<void>();
              response = _Response(
                status: 503,
                cancelGate: cancellation.future,
              );
              client = _Client(<_Open>[() => _Request(response)]);
              final provider = _provider(client);
              final result = provider.invoke(_request()).toList();
              await response.listening.future;
              if (oversized) {
                response.controller.add(List<int>.filled(16 * 1024 + 1, 0x61));
              } else {
                response.controller.addError(
                  const SocketException('PRIVATE-BODY-ERROR'),
                );
              }
              await response.disposed.future;
              cancellation.completeError(
                StateError('PRIVATE-CANCELLATION-ERROR'),
              );
              return await result;
            },
            (Object error, StackTrace stackTrace) => uncaught.add(error),
          );
          final events = await work!.timeout(_deadline);
          // Flush fire-and-forget cancellation continuations before checking the zone.
          await Future<void>.delayed(Duration.zero);

          _expectFailure(
            events,
            code: 'http_503',
            cause: oversized ? 'provider_terminal' : 'socket',
            kind: ModelProviderFailureKind.unavailable,
            stage: 'error_body',
            attempts: 1,
            retries: 0,
          );
          expect(
            events
                .single
                .terminal!
                .failure!
                .providerDetails['responseBodyTruncated'],
            isTrue,
          );
          expect(
            events.single.terminal!.failure!.providerMessage,
            isNot(contains('PRIVATE')),
          );
          expect(response.cancels, 1);
          expect(client.attempts, 1);
          expect(uncaught, isEmpty);
        },
      );
    }

    test('late headers are cancelled even when request abort throws', () async {
      final lateResponse = _success();
      final headers = Completer<HttpClientResponse>();
      final lateRequest = _Request(
        lateResponse,
        openResponse: () => headers.future,
        abortFailure: StateError('PRIVATE-ABORT-ERROR'),
      );
      final currentResponse = _Response();
      final client = _Client(<_Open>[
        () => lateRequest,
        () => _Request(currentResponse),
      ]);
      final provider = _provider(client, responseOpenTimeout: _shortTimeout);
      final result = provider.invoke(_request()).toList();
      await currentResponse.listening.future.timeout(_deadline);
      headers.complete(lateResponse);
      await lateResponse.disposed.future.timeout(_deadline);
      currentResponse.complete('current-response');
      final events = await result.timeout(_deadline);

      _expectCompleted(events);
      expect(events, hasLength(1));
      expect(events.single.terminal!.responseId, 'current-response');
      expect(lateResponse.cancels, 1);
      expect(lateRequest.aborts, greaterThanOrEqualTo(2));
      expect(client.attempts, 2);
    });

    for (final type in <String>['response.failed', 'error']) {
      test('$type diagnostics redact before the 4096 character cap', () async {
        final prefix = List<String>.filled(4090, 'x').join();
        final oversized =
            '$prefix$_secret${List<String>.filled(8192, 'z').join()}';
        final error = <String, Object?>{
          'code': oversized,
          'message': oversized,
        };
        final response = _Response()
          ..headers.set('x-request-id', oversized)
          ..send(<String, Object?>{
            'type': type,
            if (type == 'response.failed')
              'response': <String, Object?>{
                'id': oversized,
                'model': oversized,
                'error': error,
              }
            else
              'error': error,
          });
        final client = _Client(<_Open>[() => _Request(response)]);
        final provider = _provider(client);

        final events = await provider
            .invoke(_request())
            .toList()
            .timeout(_deadline);

        expect(events, hasLength(1));
        final terminal = events.single.terminal!;
        expect(terminal.settlement, ModelProviderSettlement.failed);
        expect(
          terminal.failure!.kind,
          ModelProviderFailureKind.providerFailure,
        );
        for (final diagnostic in <String?>[
          terminal.failure!.providerCode,
          terminal.failure!.providerMessage,
          terminal.requestId,
          if (type == 'response.failed') terminal.responseId,
          if (type == 'response.failed') terminal.effectiveModel,
        ]) {
          expect(diagnostic, isNotNull);
          expect(diagnostic!.length, lessThanOrEqualTo(4096));
          expect(diagnostic, startsWith(prefix));
          expect(
            diagnostic,
            isNot(contains('PRIVAT')),
            reason:
                'Truncating before redaction leaks the start of the boundary-crossing secret.',
          );
        }
        expect(client.attempts, 1);
      });
    }

    test(
      'HTTP request ID and retry-after diagnostics redact before capping',
      () async {
        final prefix = List<String>.filled(4090, 'x').join();
        final oversized =
            '$prefix$_secret${List<String>.filled(8192, 'z').join()}';
        final response = _jsonResponse(<String, Object?>{}, status: 503)
          ..headers.set('x-request-id', oversized)
          ..headers.set(HttpHeaders.retryAfterHeader, oversized);
        final client = _Client(<_Open>[() => _Request(response)]);
        final provider = _provider(client);

        final events = await provider
            .invoke(_request())
            .toList()
            .timeout(_deadline);

        final terminal = events.single.terminal!;
        expect(terminal.failure!.providerCode, 'http_503');
        for (final diagnostic in <String?>[
          terminal.requestId,
          terminal.failure!.providerDetails['requestId'] as String?,
          terminal.failure!.providerDetails['retryAfter'] as String?,
        ]) {
          expect(diagnostic, isNotNull);
          expect(diagnostic!.length, lessThanOrEqualTo(4096));
          expect(diagnostic, startsWith(prefix));
          expect(diagnostic, isNot(contains('PRIVAT')));
        }
        expect(client.attempts, 1);
      },
    );

    test(
      'diagnostic cap leaves semantic and native output unchanged',
      () async {
        final text = '${List<String>.filled(8192, 'x').join()}$_secret';
        final native = <String, Object?>{
          'type': 'reasoning',
          'id': 'native-long',
          'encrypted_content': text,
          'summary': <Object?>[
            <String, Object?>{'type': 'summary_text', 'text': text},
          ],
        };
        final response = _Response()
          ..send(<String, Object?>{
            'type': 'response.output_text.delta',
            'delta': text,
          })
          ..send(
            _item(<String, Object?>{
              'type': 'message',
              'role': 'assistant',
              'content': <Object?>[
                <String, Object?>{
                  'type': 'output_text',
                  'text': text,
                  'annotations': <Object?>[],
                },
              ],
            }),
          )
          ..send(_item(native))
          ..complete();
        final client = _Client(<_Open>[() => _Request(response)]);
        final provider = _provider(client);

        final events = await provider
            .invoke(_request())
            .toList()
            .timeout(_deadline);

        _expectCompleted(events);
        expect(events, hasLength(4));
        expect(events[0].observation!.textDelta, text);
        expect(events[1].output!.text, text);
        expect(events[2].output!.nativeMetadata!.data['item'], native);
        expect(client.attempts, 1);
      },
    );

    test(
      'diagnostics redact captured endpoint and standalone query values',
      () async {
        const querySecret = 'PRIVATE-ENDPOINT-QUERY';
        final endpoint = Uri.parse(
          'https://private.example.test/responses?token=$querySecret',
        );
        final diagnostic = 'Endpoint $endpoint query $querySecret';
        final response =
            _jsonResponse(<String, Object?>{
                'error': <String, Object?>{
                  'code': diagnostic,
                  'message': diagnostic,
                },
              }, status: 503)
              ..headers.set('x-request-id', diagnostic)
              ..headers.set(HttpHeaders.retryAfterHeader, diagnostic);
        final client = _Client(<_Open>[() => _Request(response)]);
        final provider = _provider(client, endpoint: endpoint);

        final events = await provider
            .invoke(_request())
            .toList()
            .timeout(_deadline);

        final terminal = events.single.terminal!;
        final diagnostics = jsonEncode(<Object?>[
          terminal.requestId,
          terminal.failure!.providerCode,
          terminal.failure!.providerMessage,
          terminal.failure!.providerDetails,
        ]);
        expect(diagnostics, isNot(contains(endpoint.toString())));
        expect(diagnostics, isNot(contains(querySecret)));
        expect(diagnostics, contains('[REDACTED]'));
        expect(client.attempts, 1);
      },
    );

    for (final bool chatGpt in <bool>[false, true]) {
      test(
        '${chatGpt ? 'ChatGPT' : 'API key'} owned client close is idempotent',
        () async {
          final client = _Client(<_Open>[]);
          final auth = chatGpt ? await _auth(_Client(<_Open>[])) : null;
          final provider = HttpOverrides.runZoned(
            () => chatGpt
                ? OpenAiModelProvider.chatGpt(auth: auth!)
                : OpenAiModelProvider(apiKey: _secret),
            createHttpClient: (SecurityContext? context) => client,
          );
          addTearDown(provider.close);
          provider.close();
          provider.close();
          provider.close();

          final events = await provider
              .invoke(_request())
              .toList()
              .timeout(_deadline);

          expect(client.closes, 1);
          expect(client.attempts, 0);
          expect(
            events.single.terminal!.failure!.providerCode,
            'provider_closed',
          );
        },
      );
    }
  });

  group('ChatGPT independent recovery budgets', () {
    for (final bool authFirst in <bool>[false, true]) {
      for (final bool exhaust in <bool>[false, true]) {
        test(
          '${authFirst ? '401 then transport' : 'transport then 401'} ${exhaust ? 'fails at three attempts' : 'recovers'}',
          () async {
            final oauthClient = _Client(<_Open>[
              () => _Request(
                _jsonResponse(<String, Object?>{
                  'access_token': 'PRIVATE-REFRESHED-ACCESS',
                  'expires_in': 3600,
                }),
              ),
            ]);
            final auth = await _auth(oauthClient);
            final unauthorized = _jsonResponse(
              <String, Object?>{
                'error': <String, Object?>{'message': 'unauthorized'},
              },
              status: 401,
            )..headers.set('x-codex-turn-state', 'PRIVATE-REJECTED-TOKEN');
            final premature = _Response()
              ..headers.set('x-codex-turn-state', 'PRIVATE-FIRST-TOKEN');
            unawaited(premature.controller.close());
            final finalResponse = (exhaust ? _Response() : _success())
              ..headers.set('x-codex-turn-state', 'PRIVATE-LATER-TOKEN');
            if (exhaust) unawaited(finalResponse.controller.close());
            final requests = <_Request>[
              _Request(authFirst ? unauthorized : premature),
              _Request(authFirst ? premature : unauthorized),
              _Request(finalResponse),
            ];
            final client = _Client(<_Open>[
              for (final request in requests) () => request,
            ]);
            final provider = _chatGptProvider(client, auth);

            final events = await provider
                .invoke(
                  _request(
                    affinity: ModelProviderAffinity(
                      id: 'PRIVATE-SCOPE',
                      state: null,
                    ),
                  ),
                )
                .toList()
                .timeout(_deadline);

            expect(client.attempts, 3);
            expect(oauthClient.attempts, 1);
            expect(
              requests.first.headers.value(HttpHeaders.authorizationHeader),
              'Bearer PRIVATE-ACCESS',
            );
            expect(
              requests.last.headers.value(HttpHeaders.authorizationHeader),
              'Bearer PRIVATE-REFRESHED-ACCESS',
            );
            expect(
              requests.map(
                (request) => request.headers.value('x-codex-turn-state'),
              ),
              <String?>[
                null,
                if (authFirst) null else 'PRIVATE-FIRST-TOKEN',
                'PRIVATE-FIRST-TOKEN',
              ],
            );
            expect(
              events.single.terminal!.affinityState!.data['turnState'],
              'PRIVATE-FIRST-TOKEN',
            );
            expect(
              requests.map((request) => request.body.toString()),
              everyElement(requests.first.body.toString()),
            );
            if (exhaust) {
              _expectFailure(
                events,
                code: 'missing_terminal',
                cause: 'premature_eof',
                kind: ModelProviderFailureKind.malformedResponse,
                attempts: 3,
              );
            } else {
              _expectCompleted(events);
            }
          },
        );
      }
    }

    test('second 401 cannot consume another auth recovery', () async {
      final oauthClient = _Client(<_Open>[
        () => _Request(
          _jsonResponse(<String, Object?>{
            'access_token': 'PRIVATE-REFRESHED-ACCESS',
            'expires_in': 3600,
          }),
        ),
      ]);
      final auth = await _auth(oauthClient);
      final client = _Client(<_Open>[
        _failedOpen('connection', const SocketException('reset')),
        () => _Request(_jsonResponse(<String, Object?>{}, status: 401)),
        () => _Request(_jsonResponse(<String, Object?>{}, status: 401)),
      ]);
      final provider = _chatGptProvider(client, auth);

      final events = await provider
          .invoke(_request())
          .toList()
          .timeout(_deadline);

      expect(client.attempts, 3);
      expect(oauthClient.attempts, 1);
      expect(events, hasLength(1));
      expect(
        events.single.terminal!.failure!.kind,
        ModelProviderFailureKind.authentication,
      );
    });

    test(
      'first successful response affinity survives pre-output transport retry',
      () async {
        final auth = await _auth(_Client(<_Open>[]));
        final first = _Response()
          ..headers.set('x-codex-turn-state', 'PRIVATE-FIRST-TOKEN');
        unawaited(first.controller.close());
        final second = _success()
          ..headers.set('x-codex-turn-state', 'PRIVATE-LATER-TOKEN');
        final retry = _Request(second);
        final client = _Client(<_Open>[() => _Request(first), () => retry]);
        final provider = _chatGptProvider(client, auth);

        final events = await provider
            .invoke(
              _request(
                affinity: ModelProviderAffinity(
                  id: 'PRIVATE-SCOPE',
                  state: null,
                ),
              ),
            )
            .toList()
            .timeout(_deadline);

        _expectCompleted(events);
        expect(
          retry.headers.value('x-codex-turn-state'),
          'PRIVATE-FIRST-TOKEN',
        );
        expect(
          events.single.terminal!.affinityState!.data['turnState'],
          'PRIVATE-FIRST-TOKEN',
        );
        expect(client.attempts, 2);
      },
    );

    test('late timed-out response headers cannot capture affinity', () async {
      final auth = await _auth(_Client(<_Open>[]));
      final late = _success()
        ..headers.set('x-codex-turn-state', 'PRIVATE-STALE-TOKEN');
      final gate = Completer<HttpClientResponse>();
      final current = _Response()
        ..headers.set('x-codex-turn-state', 'PRIVATE-CURRENT-TOKEN');
      final retry = _Request(current);
      final client = _Client(<_Open>[
        () => _Request(late, openResponse: () => gate.future),
        () => retry,
      ]);
      final provider = _chatGptProvider(
        client,
        auth,
        responseOpenTimeout: _shortTimeout,
      );
      final result = provider
          .invoke(
            _request(
              affinity: ModelProviderAffinity(id: 'PRIVATE-SCOPE', state: null),
            ),
          )
          .toList();
      await current.listening.future.timeout(_deadline);
      gate.complete(late);
      await late.disposed.future.timeout(_deadline);
      current.complete();
      final events = await result.timeout(_deadline);

      _expectCompleted(events);
      expect(retry.headers.value('x-codex-turn-state'), isNull);
      expect(
        events.single.terminal!.affinityState!.data['turnState'],
        'PRIVATE-CURRENT-TOKEN',
      );
      expect(client.attempts, 2);
    });

    test(
      'retry captures the first usable affinity after an ambiguous header',
      () async {
        final auth = await _auth(_Client(<_Open>[]));
        final first = _Response()
          ..headers.set('x-codex-turn-state', ['PRIVATE-ONE', 'PRIVATE-TWO']);
        unawaited(first.controller.close());
        final second = _success()
          ..headers.set('x-codex-turn-state', 'PRIVATE-USABLE');
        final retry = _Request(second);
        final client = _Client(<_Open>[() => _Request(first), () => retry]);
        final provider = _chatGptProvider(client, auth);
        final events = await provider
            .invoke(
              _request(
                affinity: ModelProviderAffinity(
                  id: 'PRIVATE-SCOPE',
                  state: null,
                ),
              ),
            )
            .toList()
            .timeout(_deadline);
        _expectCompleted(events);
        expect(client.attempts, 2);
        expect(retry.headers.value('session-id'), 'PRIVATE-SCOPE');
        expect(retry.headers.value('x-codex-turn-state'), isNull);
        expect(
          events.single.terminal!.affinityState!.data['turnState'],
          'PRIVATE-USABLE',
        );
      },
    );

    test(
      'retry diagnostics redact credentials, account, scope and all observed affinity tokens',
      () async {
        final auth = await _auth(_Client(<_Open>[]));
        const secrets = <String>[
          'PRIVATE-ACCESS',
          'PRIVATE-ACCOUNT',
          'PRIVATE-SCOPE',
          'PRIVATE-FIRST-TOKEN',
          'PRIVATE-LATER-TOKEN',
        ];
        final responses = <_Response>[
          for (final token in <String>[
            'PRIVATE-FIRST-TOKEN',
            'PRIVATE-LATER-TOKEN',
          ])
            _Response()
              ..headers.set('x-codex-turn-state', token)
              ..headers.set('x-request-id', secrets.join('/'))
              ..controller.addError(HttpException(secrets.join('/'))),
        ];
        final client = _Client(<_Open>[
          for (final response in responses) () => _Request(response),
        ]);
        final provider = _chatGptProvider(client, auth);

        final events = await provider
            .invoke(
              _request(
                affinity: ModelProviderAffinity(
                  id: 'PRIVATE-SCOPE',
                  state: null,
                ),
              ),
            )
            .toList()
            .timeout(_deadline);

        _expectFailure(events, code: 'stream_transport', cause: 'http');
        final terminal = events.single.terminal!;
        final diagnostics = jsonEncode(<Object?>[
          terminal.requestId,
          terminal.failure!.providerMessage,
          terminal.failure!.providerDetails,
        ]);
        for (final secret in secrets) {
          expect(diagnostics, isNot(contains(secret)));
        }
        expect(
          terminal.affinityState!.data['turnState'],
          'PRIVATE-FIRST-TOKEN',
        );
        expect(client.attempts, 2);
      },
    );
  });
}

OpenAiModelProvider _provider(
  _Client client, {
  Uri? endpoint,
  Duration responseOpenTimeout = const Duration(seconds: 1),
  Duration inactivityTimeout = const Duration(seconds: 1),
  Duration transportRetryDelay = Duration.zero,
  Duration cleanupTimeout = _shortTimeout,
}) {
  final provider = OpenAiModelProvider(
    apiKey: _secret,
    endpoint: endpoint,
    httpClient: client,
    responseOpenTimeout: responseOpenTimeout,
    inactivityTimeout: inactivityTimeout,
    transportRetryDelay: transportRetryDelay,
    cleanupTimeout: cleanupTimeout,
  );
  addTearDown(provider.close);
  return provider;
}

OpenAiModelProvider _chatGptProvider(
  _Client client,
  OpenAiChatGptAuth auth, {
  Duration responseOpenTimeout = const Duration(seconds: 1),
}) {
  final provider = OpenAiModelProvider.chatGpt(
    auth: auth,
    httpClient: client,
    responseOpenTimeout: responseOpenTimeout,
    inactivityTimeout: const Duration(seconds: 1),
    transportRetryDelay: Duration.zero,
    cleanupTimeout: _shortTimeout,
  );
  addTearDown(provider.close);
  return provider;
}

ModelProviderRequest _request({ModelProviderAffinity? affinity}) =>
    ModelProviderRequest(
      model: 'test-model',
      instructions: 'Test reliability.',
      input: const <ModelProviderInput>[],
      tools: const <ModelProviderTool>[],
      toolChoice: ModelProviderToolChoice.auto,
      maxOutputTokens: null,
      providerOptions: const <String, Object?>{},
      nativeState: null,
      affinity: affinity,
    );

void _expectCompleted(List<ModelProviderEvent> events) {
  expect(events.where((event) => event.terminal != null), hasLength(1));
  expect(events.last.kind, ModelProviderEventKind.terminal);
  expect(events.last.terminal!.settlement, ModelProviderSettlement.completed);
  expect(events.last.terminal!.failure, isNull);
}

void _expectFailure(
  List<ModelProviderEvent> events, {
  required String code,
  required String cause,
  String stage = 'sse',
  ModelProviderFailureKind kind = ModelProviderFailureKind.transport,
  int attempts = 2,
  int retries = 1,
  bool published = false,
  int? osErrorCode,
}) {
  expect(events.where((event) => event.terminal != null), hasLength(1));
  if (!published) expect(events, hasLength(1));
  final terminal = events.last.terminal!;
  expect(terminal.settlement, ModelProviderSettlement.failed);
  final failure = terminal.failure!;
  expect(failure.kind, kind);
  expect(failure.providerCode, code);
  expect(failure.providerDetails['transportStage'], stage);
  expect(failure.providerDetails['cause'], cause);
  expect(failure.providerDetails['httpAttemptCount'], attempts);
  expect(failure.providerDetails['transportRetryCount'], retries);
  expect(failure.providerDetails['outputPublished'], published);
  if (osErrorCode != null) {
    expect(failure.providerDetails['osErrorCode'], osErrorCode);
  }
}

Map<String, Object?> _item(Map<String, Object?> item) => <String, Object?>{
  'type': 'response.output_item.done',
  'item': item,
};

Map<String, Object?> _textOutput() => _item(<String, Object?>{
  'type': 'message',
  'id': 'message-1',
  'role': 'assistant',
  'content': <Object?>[
    <String, Object?>{
      'type': 'output_text',
      'text': 'Authoritative.',
      'annotations': <Object?>[],
    },
  ],
});

_Response _success() => _Response()..complete();

_Response _jsonResponse(Map<String, Object?> value, {int status = 200}) {
  final response = _Response(status: status)
    ..controller.add(utf8.encode(jsonEncode(value)));
  unawaited(response.controller.close());
  return response;
}

_Open _failedOpen(String stage, Object error) => () {
  if (stage == 'connection') throw error;
  final response = _Response(status: stage == 'error_body' ? 503 : 200);
  if (stage == 'request_submission') {
    return _Request(response, writeFailure: error);
  }
  if (stage == 'response_headers') {
    return _Request(response, openResponse: () async => throw error);
  }
  response.controller.addError(error);
  return _Request(response);
};

Future<OpenAiChatGptAuth> _auth(_Client refreshClient) async {
  final oauth = OpenAiOAuthClient(
    configuration: OpenAiOAuthConfiguration(
      clientId: 'test-client',
      issuer: Uri.parse('https://auth.example.test'),
      redirectUri: Uri.parse('http://127.0.0.1:1455/auth/callback'),
    ),
    refreshHttpClient: refreshClient,
  );
  addTearDown(oauth.close);
  final auth = OpenAiChatGptAuth(
    instanceId: 'reliability-test',
    store: InMemoryOpenAiCredentialStore(),
    oauth: oauth,
  );
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  await auth.install(
    OpenAiChatGptCredential(
      idToken:
          '${encode(<String, Object?>{'alg': 'none'})}.${encode(<String, Object?>{
            'https://api.openai.com/auth': <String, Object?>{'chatgpt_account_id': 'PRIVATE-ACCOUNT'},
          })}.',
      accessToken: 'PRIVATE-ACCESS',
      refreshToken: 'PRIVATE-REFRESH',
      accountId: 'PRIVATE-ACCOUNT',
      fedRamp: false,
      expiresAt: null,
    ),
  );
  return auth;
}

typedef _Open = FutureOr<HttpClientRequest> Function();

final class _Client implements HttpClient {
  _Client(this.script);

  final List<_Open> script;
  final started = Completer<void>();
  int attempts = 0;
  int closes = 0;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    final index = attempts++;
    if (!started.isCompleted) started.complete();
    if (index >= script.length) {
      throw StateError('Unexpected HTTP attempt ${index + 1}.');
    }
    return await script[index]();
  }

  @override
  void close({bool force = false}) => closes++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Request implements HttpClientRequest {
  _Request(
    this.response, {
    this.openResponse,
    this.writeFailure,
    this.abortFailure,
  });

  final _Response response;
  final Future<HttpClientResponse> Function()? openResponse;
  final Object? writeFailure;
  final Object? abortFailure;
  final body = StringBuffer();
  final opening = Completer<void>();
  final aborted = Completer<void>();
  int aborts = 0;
  int responseOpens = 0;

  @override
  final headers = _Headers();

  @override
  bool followRedirects = true;

  @override
  void write(Object? object) {
    if (writeFailure case final failure?) throw failure;
    body.write(object);
  }

  @override
  Future<HttpClientResponse> close() async {
    responseOpens++;
    if (!opening.isCompleted) opening.complete();
    return openResponse == null ? response : await openResponse!();
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborts++;
    if (!aborted.isCompleted) aborted.complete();
    if (abortFailure case final failure?) throw failure;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Headers implements HttpHeaders {
  final values = <String, List<String>>{};

  @override
  ContentType? contentType;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value is Iterable
        ? value.map((Object? value) => '$value').toList()
        : <String>['$value'];
  }

  @override
  String? value(String name) {
    final entries = values[name.toLowerCase()];
    if (entries == null || entries.isEmpty) return null;
    if (entries.length > 1) {
      throw HttpException('More than one value for header $name.');
    }
    return entries.single;
  }

  @override
  List<String>? operator [](String name) => values[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response({this.status = 200, Future<void>? cancelGate}) {
    controller = StreamController<List<int>>(
      sync: true,
      onListen: listening.complete,
      onPause: () => pauses++,
      onResume: () => resumes++,
      onCancel: () {
        cancels++;
        if (!disposed.isCompleted) disposed.complete();
        return cancelGate;
      },
    );
  }

  final int status;
  final listening = Completer<void>();
  final disposed = Completer<void>();
  late final StreamController<List<int>> controller;
  int pauses = 0;
  int resumes = 0;
  int cancels = 0;

  @override
  final headers = _Headers();

  @override
  int get statusCode => status;

  void send(Map<String, Object?> event) =>
      controller.add(utf8.encode('data: ${jsonEncode(event)}\n\n'));

  void complete([String id = 'completed-response']) => send(<String, Object?>{
    'type': 'response.completed',
    'response': <String, Object?>{'id': id},
  });

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => controller.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
