import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_model_provider/adele_model_catalog.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:openai_model_provider_backend/openai_model_provider_backend.dart';
import 'package:test/test.dart';

const _key = 'sentinel-api-key';
const _endpoint = 'https://private.example.test:8443/tenant/responses';
const _catalogEndpoint = 'https://private.example.test:8443/tenant/models';
const _privateText =
    'sentinel-raw-body sentinel-native-exception $_key $_endpoint';
const _maxBodyBytes = 4 * 1024 * 1024;

void main() {
  group('catalog response', () {
    test(
      'preserves exact IDs and order with null metadata and no extras',
      () async {
        final harness = _Harness();
        await harness.run(() async {
          final result = harness.catalog.listModels();
          harness.host.reply(0, {'secret': _key});
          await _pump();
          final client = harness.clients.single;
          final ids = [
            'z-last',
            'ft:organization/model:2026-11-16',
            'A',
            'a',
            ' model with spaces ',
            'model-\u00e9',
            'x' * 1024,
          ];
          final bytes = utf8.encode(
            jsonEncode({
              'object': 'list',
              'data': [
                for (final id in ids)
                  {
                    ..._model(id),
                    'created': {'unexpected': _privateText},
                    'owned_by': [_privateText],
                    'display_name': _privateText,
                    'description': _privateText,
                    'capabilities': {'tools': true},
                  },
              ],
              'has_more': true,
              'next': _privateText,
              'unknown': {'nested': _privateText},
            }),
          );
          // Split every byte, including the multibyte UTF-8 model ID.
          for (final byte in bytes) {
            client.response.controller.add([byte]);
          }
          unawaited(client.response.controller.close());
          final snapshot = await result;
          expect(snapshot.models.map((model) => model.modelId), ids);
          expect(
            snapshot.models.map((model) => model.displayName),
            everyElement(isNull),
          );
          expect(
            snapshot.models.map((model) => model.description),
            everyElement(isNull),
          );
          expect(() => snapshot.models.clear(), throwsUnsupportedError);
          _expectReleased(client);
          expect(client.urls, [Uri.parse('https://api.openai.com/v1/models')]);
          expect(client.request.headers.values, {
            HttpHeaders.acceptHeader: 'application/json',
            HttpHeaders.authorizationHeader: 'Bearer $_key',
          });
          expect(client.request.followRedirects, isFalse);
          expect(client.request.closes, 1);
          expect(harness.host.requests, hasLength(1));
        });
      },
    );

    test('empty discovery is a successful empty snapshot', () async {
      final harness = _Harness();
      await harness.run(() async {
        final result = harness.catalog.listModels();
        harness.host.reply(0, {'secret': _key});
        await _pump();
        harness.clients.single.response.json(_list([]));
        expect((await result).models, isEmpty);
        _expectReleased(harness.clients.single);
      });
    });

    for (final (label, payload) in <(String, Object?)>[
      ('null root', null),
      ('array root', []),
      ('string root', _privateText),
      ('number root', 42),
      ('missing list discriminator', {'data': <Object?>[]}),
      ('null list discriminator', {'object': null, 'data': <Object?>[]}),
      ('wrong list discriminator', {'object': 'model', 'data': <Object?>[]}),
      (
        'case-sensitive list discriminator',
        {'object': 'List', 'data': <Object?>[]},
      ),
      ('missing data', {'object': 'list'}),
      ('null data', {'object': 'list', 'data': null}),
      ('map data', {'object': 'list', 'data': <String, Object?>{}}),
      ('string data', {'object': 'list', 'data': _privateText}),
      ('null model', _list([null])),
      ('string model', _list([_privateText])),
      ('array model', _list([[]])),
      (
        'missing model discriminator',
        _list([
          {'id': 'model'},
        ]),
      ),
      (
        'null model discriminator',
        _list([
          {'object': null, 'id': 'model'},
        ]),
      ),
      (
        'wrong model discriminator',
        _list([
          {'object': 'list', 'id': 'model'},
        ]),
      ),
      (
        'case-sensitive model discriminator',
        _list([
          {'object': 'Model', 'id': 'model'},
        ]),
      ),
      (
        'missing ID',
        _list([
          {'object': 'model'},
        ]),
      ),
      ('null ID', _list([_model(null)])),
      ('numeric ID', _list([_model(42)])),
      ('boolean ID', _list([_model(true)])),
      ('empty ID', _list([_model('')])),
      ('blank ID', _list([_model('   ')])),
      ('NUL in ID', _list([_model('model\u0000hidden')])),
      ('newline in ID', _list([_model('model\nhidden')])),
      ('carriage return in ID', _list([_model('model\rhidden')])),
      ('tab in ID', _list([_model('model\thidden')])),
      ('DEL in ID', _list([_model('model\u007fhidden')])),
      ('oversized ID', _list([_model('x' * 1025)])),
      ('duplicate IDs', _list([_model('same'), _model('same')])),
      ('invalid after valid ID', _list([_model('valid'), _model('')])),
      ('reflected key', _list([_model('model-$_key')])),
      ('reflected configured endpoint', _list([_model('model-$_endpoint')])),
      (
        'reflected catalog endpoint',
        _list([_model('model-$_catalogEndpoint')]),
      ),
    ]) {
      test('$label fails the entire snapshot with safe diagnostics', () async {
        final harness = _Harness(endpoint: _endpoint);
        await harness.run(() async {
          final failed = expectLater(
            harness.catalog.listModels(),
            _fails('malformed_response'),
          );
          harness.host.reply(0, {'secret': _key});
          await _pump();
          harness.clients.single.response.json(payload);
          await failed;
          _expectReleased(harness.clients.single);
          expect(harness.clients, hasLength(1));
          expect(harness.host.requests, hasLength(1));
        });
      });
    }

    for (final (label, bytes) in <(String, List<int>)>[
      ('empty body', []),
      ('malformed JSON', utf8.encode('{$_privateText')),
      ('truncated JSON', utf8.encode('{"object":"list","data":[')),
      ('trailing JSON', utf8.encode('${jsonEncode(_list([]))} null')),
      ('malformed UTF-8', [0xc3, 0x28]),
      ('truncated UTF-8', [...utf8.encode(jsonEncode(_list([]))), 0xc3]),
    ]) {
      test('$label is not repaired or retried', () async {
        final harness = _Harness();
        await harness.run(() async {
          final failed = expectLater(
            harness.catalog.listModels(),
            _fails('malformed_response'),
          );
          harness.host.reply(0, {'secret': _key});
          await _pump();
          harness.clients.single.response.bytes(bytes);
          await failed;
          _expectReleased(harness.clients.single);
          expect(harness.host.requests, hasLength(1));
        });
      });
    }

    for (final count in [1024, 1025]) {
      test('enforces the 1024-entry boundary ($count entries)', () async {
        final harness = _Harness();
        await harness.run(() async {
          final result = harness.catalog.listModels();
          final failed = count > 1024
              ? expectLater(result, _fails('malformed_response'))
              : null;
          harness.host.reply(0, {'secret': _key});
          await _pump();
          final ids = List.generate(count, (index) => 'model-$index');
          harness.clients.single.response.json(_list(ids.map(_model).toList()));
          if (failed != null) {
            await failed;
          } else {
            expect((await result).models.map((model) => model.modelId), ids);
          }
          _expectReleased(harness.clients.single);
        });
      });
    }

    test('accepts exactly 4 MiB including ignored response fields', () async {
      final harness = _Harness();
      await harness.run(() async {
        final result = harness.catalog.listModels();
        harness.host.reply(0, {'secret': _key});
        await _pump();
        final prefix = utf8.encode('{"object":"list","data":[],"ignored":"');
        final suffix = utf8.encode('"}');
        final padding = Uint8List(_maxBodyBytes - prefix.length - suffix.length)
          ..fillRange(0, _maxBodyBytes - prefix.length - suffix.length, 0x20);
        final response = harness.clients.single.response;
        response.controller.add(prefix);
        response.controller.add(padding);
        response.bytes(suffix);
        expect((await result).models, isEmpty);
        _expectReleased(harness.clients.single);
      });
    });

    test(
      'rejects streamed overflow before EOF, not just content length',
      () async {
        final harness = _Harness();
        await harness.run(() async {
          final failed = expectLater(
            harness.catalog.listModels(),
            _fails('malformed_response'),
          );
          harness.host.reply(0, {'secret': _key});
          await _pump();
          final response = harness.clients.single.response;
          response.controller.add(
            Uint8List(_maxBodyBytes - 1)..fillRange(0, _maxBodyBytes - 1, 0x20),
          );
          expect(response.cancels, 0);
          response.controller.add([0x20, 0x20]);
          await failed;
          expect(response.controller.isClosed, isFalse);
          _expectReleased(harness.clients.single);
          // Even a later valid body has no publication authority.
          response.json(_list([_model('late')]));
          await _pump();
          expect(harness.clients, hasLength(1));
        });
      },
    );
  });

  group('configured endpoint and credentials', () {
    test('construction does not read credentials or allocate HTTP', () async {
      final harness = _Harness();
      await harness.run(() async {
        await _pump();
        expect(harness.host.requests, isEmpty);
        expect(harness.clients, isEmpty);
        harness.catalog.close();
        harness.catalog.close();
        await expectLater(harness.catalog.listModels(), _fails('unavailable'));
        expect(harness.host.requests, isEmpty);
        expect(harness.clients, isEmpty);
      });
    });

    for (final (endpoint, expected) in <(String?, String)>[
      (null, 'https://api.openai.com/v1/models'),
      (_endpoint, _catalogEndpoint),
      ('https://example.test/responses', 'https://example.test/models'),
      (
        'https://example.test:8443/tenant%2Fscope/v2/responses',
        'https://example.test:8443/tenant%2Fscope/v2/models',
      ),
      ('http://127.0.0.2:8080/responses', 'http://127.0.0.2:8080/models'),
      (
        'http://localhost:8080/prefix/responses',
        'http://localhost:8080/prefix/models',
      ),
      (
        'https://[2001:db8::1]:8443/prefix/responses',
        'https://[2001:db8::1]:8443/prefix/models',
      ),
    ]) {
      test(
        'derives only the terminal path and retains authority: $endpoint',
        () async {
          final harness = _Harness(endpoint: endpoint, recordId: 'personal');
          await harness.run(() async {
            final result = harness.catalog.listModels();
            expect(harness.clients, isEmpty);
            final request = harness.host.requests.single;
            expect(request['hostContextKind'], 'infrastructure');
            expect(request['hostContext'], 'generation-grant');
            expect(request['serviceId'], backendCredentialServiceId);
            expect(request['payload'], {
              'collection': 'providers',
              'recordType': openAiApiKeyProviderId,
              'recordId': 'personal',
              'slot': 'api-key',
            });
            harness.host.reply(0, {'secret': _key});
            await _pump();
            final client = harness.clients.single;
            expect(client.urls, [Uri.parse(expected)]);
            client.response.json(_list([]));
            await result;
            _expectReleased(client);
          });
        },
      );
    }

    for (final endpoint in [
      'https://example.test/v1/responses?api-key=sentinel-query',
      'https://example.test/v1/responses?',
      'https://example.test/v1/responses/',
      'https://example.test/v1/responses/extra',
      'https://example.test/v1/responses-other',
      'https://example.test/v1/notresponses',
      'https://example.test/v1/Responses',
      'https://example.test/v1%2Fresponses',
      'https://example.test/v1/chat/completions',
      'https://example.test/v1/models',
      'https://example.test/',
    ]) {
      test(
        'unsupported discovery rejects before credentials and HTTP: $endpoint',
        () async {
          final harness = _Harness(endpoint: endpoint);
          await harness.run(() async {
            await expectLater(
              harness.catalog.listModels(),
              _fails('unsupported_discovery'),
            );
            expect(harness.host.requests, isEmpty);
            expect(harness.clients, isEmpty);
          });
        },
      );
    }

    for (final kind in AdeleCredentialFailureKind.values) {
      test('host $kind is unavailable, not remote authentication', () async {
        final harness = _Harness();
        await harness.run(() async {
          final failed = expectLater(
            harness.catalog.listModels(),
            _fails('unavailable'),
          );
          harness.host.reply(0, {'failure': kind.name});
          await failed;
          expect(harness.host.requests, hasLength(1));
          expect(harness.clients, isEmpty);
        });
      });
      test('injected reader maps $kind without startup credentials', () async {
        final harness = _Harness(
          withCredentials: false,
          readCredential: () async => throw AdeleCredentialFailure(kind),
        );
        await harness.run(() async {
          await expectLater(
            harness.catalog.listModels(),
            _fails('unavailable'),
          );
          expect(harness.host.requests, isEmpty);
          expect(harness.clients, isEmpty);
        });
      });
    }

    test(
      'unexpected reader failure is opaque without startup fallback',
      () async {
        var reads = 0;
        final harness = _Harness(
          readCredential: () {
            reads++;
            throw StateError(_privateText);
          },
        );
        await harness.run(() async {
          final result = _dispatch(harness.catalog);
          await _pump();
          expect(reads, 1);
          expect(harness.host.requests, isEmpty);
          expect(harness.clients, isEmpty);
          expect(await result, _internalError);
        });
      },
    );

    for (final (index, payload) in <Object?>[
      {'secret': ''},
      {'secret': '   '},
      {'secret': ' $_key'},
      {'secret': '$_key '},
      {'secret': '$_key\rhidden'},
      {'secret': '$_key\nhidden'},
      {'secret': '$_key\u0000hidden'},
      {'secret': '$_key\thidden'},
      {'secret': '$_key\u001fhidden'},
      {'secret': '$_key\u007fhidden'},
      {'secret': '$_key\u00e9hidden'},
      {'secret': _key, 'raw': _privateText},
      {'failure': _privateText},
      _privateText,
    ].indexed) {
      test(
        'invalid credential payload $index is safe and does not start HTTP',
        () async {
          final harness = _Harness();
          await harness.run(() async {
            final failed = expectLater(
              harness.catalog.listModels(),
              _fails('unavailable'),
            );
            harness.host.reply(0, payload);
            await failed;
            expect(harness.clients, isEmpty);
          });
        },
      );
    }

    test('missing grant fails without a reverse request or HTTP', () async {
      final harness = _Harness(withCredentials: false);
      await harness.run(() async {
        await expectLater(harness.catalog.listModels(), _fails('unavailable'));
        expect(harness.host.requests, isEmpty);
        expect(harness.clients, isEmpty);
      });
    });

    test('multiplexer closure safely settles a pending read', () async {
      final harness = _Harness();
      await harness.run(() async {
        final failed = expectLater(
          harness.catalog.listModels(),
          _fails('unavailable'),
        );
        harness.host.mux.close();
        await failed;
        harness.host.reply(0, {'secret': _key});
        await _pump();
        expect(harness.clients, isEmpty);
      });
    });

    test(
      'injected capture reads lazily and freshly without startup fallback',
      () async {
        late final AdeleCredentialCapture capture;
        final harness = _Harness(
          readCredential: () => capture.readCredential(
            collection: 'providers',
            recordType: openAiApiKeyProviderId,
            recordId: 'work',
            slot: 'api-key',
          ),
        );
        await harness.run(() async {
          await _pump();
          expect(harness.host.requests, isEmpty);
          expect(harness.clients, isEmpty);
          final capturing = harness.host.client.captureCurrentConfiguration();
          final handle = '${'b' * 32}-0000000000000001';
          harness.host.reply(0, {
            'capture': handle,
            'records': [
              {
                'collection': 'providers',
                'type': openAiApiKeyProviderId,
                'id': 'work',
                'values': {'display-name': 'Configured account'},
              },
            ],
            'isComplete': true,
          });
          capture = await capturing;
          for (var index = 0; index < 2; index++) {
            final result = harness.catalog.listModels();
            expect(harness.host.requests, hasLength(index + 2));
            expect(
              harness.host.requests.last['method'],
              'readCapturedCredential',
            );
            expect(harness.host.requests.last['payload'], {
              'capture': handle,
              'collection': 'providers',
              'recordType': openAiApiKeyProviderId,
              'recordId': 'work',
              'slot': 'api-key',
            });
            expect(harness.clients, hasLength(index));
            harness.host.reply(index + 1, {'secret': 'captured-key-$index'});
            await _pump();
            final client = harness.clients[index];
            expect(
              client.request.headers.values[HttpHeaders.authorizationHeader],
              'Bearer captured-key-$index',
            );
            client.response.json(_list([_model('captured-model-$index')]));
            expect(
              (await result).models.single.modelId,
              'captured-model-$index',
            );
            _expectReleased(client);
          }
          final denied = expectLater(
            harness.catalog.listModels(),
            _fails('unavailable'),
          );
          harness.host.reply(3, {'failure': 'staleConfiguration'});
          await _pump();
          expect(harness.host.requests, hasLength(4));
          expect(
            harness.host.requests.skip(1).map((request) => request['method']),
            everyElement('readCapturedCredential'),
          );
          expect(harness.clients, hasLength(2));
          await denied;
        });
      },
    );

    test(
      'each call reads fresh credentials and list, with no cached fallback',
      () async {
        final harness = _Harness();
        await harness.run(() async {
          for (var index = 0; index < 2; index++) {
            final result = harness.catalog.listModels();
            expect(harness.host.requests, hasLength(index + 1));
            harness.host.reply(index, {'secret': 'fresh-key-$index'});
            await _pump();
            final client = harness.clients[index];
            expect(
              client.request.headers.values[HttpHeaders.authorizationHeader],
              'Bearer fresh-key-$index',
            );
            client.response.json(_list([_model('fresh-model-$index')]));
            expect((await result).models.single.modelId, 'fresh-model-$index');
            _expectReleased(client);
          }
          expect(identical(harness.clients[0], harness.clients[1]), isFalse);
          final denied = expectLater(
            harness.catalog.listModels(),
            _fails('unavailable'),
          );
          harness.host.reply(2, {'failure': 'notConfigured'});
          await denied;
          expect(harness.clients, hasLength(2));
          final failed = expectLater(
            harness.catalog.listModels(),
            _fails('malformed_response'),
          );
          harness.host.reply(3, {'secret': 'fresh-key-3'});
          await _pump();
          harness.clients.last.response.json({'object': 'invalid'});
          await failed;
          expect(harness.host.requests, hasLength(4));
          expect(harness.clients, hasLength(3));
          _expectReleased(harness.clients.last);
        });
      },
    );
  });

  group('safe failures and no retry', () {
    for (final (status, code) in [
      (401, 'authentication'),
      (403, 'authentication'),
      (429, 'rate_limited'),
      (400, 'provider_failure'),
      (404, 'provider_failure'),
      (500, 'provider_failure'),
      (503, 'provider_failure'),
      (201, 'provider_failure'),
      (204, 'provider_failure'),
      (301, 'provider_failure'),
      (302, 'provider_failure'),
      (303, 'provider_failure'),
      (307, 'provider_failure'),
      (308, 'provider_failure'),
    ]) {
      test('HTTP $status maps to $code without waiting for a body', () async {
        final harness = _Harness(
          endpoint: _endpoint,
          createClient: () => _HttpClient(status: status),
        );
        await harness.run(() async {
          final failed = expectLater(
            harness.catalog.listModels(),
            _fails(code),
          );
          harness.host.reply(0, {'secret': _key});
          await failed;
          final client = harness.clients.single;
          expect(client.response.controller.isClosed, isFalse);
          expect(client.urls, [Uri.parse(_catalogEndpoint)]);
          expect(client.request.followRedirects, isFalse);
          _expectReleased(client);
          client.response.controller.add(utf8.encode(_privateText));
          client.response.controller.addError(StateError(_privateText));
          await _pump();
          expect(harness.host.requests, hasLength(1));
          expect(harness.clients, hasLength(1));
          expect(client.request.closes, 1);
        });
      });
    }

    test(
      'real HTTP redirect does not forward authorization or contact target',
      () async {
        final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => source.close(force: true));
        addTearDown(() => target.close(force: true));
        final sourceRequests = <HttpRequest>[];
        final targetRequests = <HttpRequest>[];
        source.listen((request) {
          sourceRequests.add(request);
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.1:${target.port}/private?$_key',
          );
          request.response.write(_privateText);
          unawaited(request.response.close());
        });
        target.listen((request) {
          targetRequests.add(request);
          request.response.write(jsonEncode(_list([])));
          unawaited(request.response.close());
        });
        final harness = _Harness(
          endpoint: 'http://127.0.0.1:${source.port}/v1/responses',
        );
        final failed = expectLater(
          harness.catalog.listModels(),
          _fails('provider_failure'),
        );
        harness.host.reply(0, {'secret': _key});
        await failed;
        expect(sourceRequests, hasLength(1));
        expect(sourceRequests.single.method, 'GET');
        expect(sourceRequests.single.uri.path, '/v1/models');
        expect(
          sourceRequests.single.headers.value(HttpHeaders.authorizationHeader),
          'Bearer $_key',
        );
        expect(targetRequests, isEmpty);
        expect(harness.host.requests, hasLength(1));
      },
    );

    for (final stage in ['getUrl', 'headers', 'body']) {
      for (final error in <Object>[
        const SocketException(_privateText),
        HttpException(_privateText, uri: Uri.parse(_endpoint)),
        const HandshakeException(_privateText),
        TimeoutException(_privateText),
      ]) {
        test(
          '$stage ${error.runtimeType} is safely mapped without retry',
          () async {
            final harness = _Harness(
              endpoint: _endpoint,
              createClient: () {
                final client = _HttpClient();
                if (stage == 'getUrl') client.acquireFailure = error;
                if (stage == 'headers') client.request.closeFailure = error;
                return client;
              },
            );
            await harness.run(() async {
              final failed = expectLater(
                harness.catalog.listModels(),
                _fails('transport'),
              );
              harness.host.reply(0, {'secret': _key});
              if (stage == 'body') {
                await _pump();
                harness.clients.single.response.controller.addError(error);
              }
              await failed;
              final client = harness.clients.single;
              expect(client.urls, [Uri.parse(_catalogEndpoint)]);
              expect(client.forcedCloses, [true]);
              expect(client.request.aborts, stage == 'getUrl' ? 0 : 1);
              expect(client.response.cancels, stage == 'body' ? 1 : 0);
              expect(harness.host.requests, hasLength(1));
              expect(harness.clients, hasLength(1));
            });
          },
        );
      }
    }

    for (final stage in ['getUrl', 'headers', 'body']) {
      test(
        'unexpected $stage exception uses generated opaque internal_error',
        () async {
          final error = StateError(_privateText);
          final harness = _Harness(
            endpoint: _endpoint,
            createClient: () {
              final client = _HttpClient();
              if (stage == 'getUrl') client.acquireFailure = error;
              if (stage == 'headers') client.request.closeFailure = error;
              return client;
            },
          );
          await harness.run(() async {
            final result = _dispatch(harness.catalog);
            await _pump();
            harness.host.reply(0, {'secret': _key});
            if (stage == 'body') {
              await _pump();
              harness.clients.single.response.controller.addError(error);
            }
            expect(await result, _internalError);
            final client = harness.clients.single;
            expect(client.forcedCloses, [true]);
            expect(client.request.aborts, stage == 'getUrl' ? 0 : 1);
            expect(client.response.cancels, stage == 'body' ? 1 : 0);
            expect(client.urls, [Uri.parse(_catalogEndpoint)]);
            expect(harness.host.requests, hasLength(1));
          });
        },
      );
    }

    test(
      'client construction exceptions use generated opaque internal_error',
      () async {
        final harness = _Harness();
        var allocations = 0;
        await HttpOverrides.runZoned(
          () async {
            final result = _dispatch(harness.catalog);
            await _pump();
            harness.host.reply(0, {'secret': _key});
            expect(await result, _internalError);
            expect(allocations, 1);
            expect(harness.host.requests, hasLength(1));
          },
          createHttpClient: (_) {
            allocations++;
            throw StateError(_privateText);
          },
        );
      },
    );
  });

  group('deadlines, retirement and cleanup', () {
    for (final retire in [false, true]) {
      for (final lateFailure in [false, true]) {
        test(
          '${retire ? 'retirement' : 'opening timeout'} fences late getUrl ${lateFailure ? 'failure' : 'success'}',
          () async {
            final acquire = Completer<HttpClientRequest>();
            final clock = _Clock();
            final harness = _Harness(
              createClient: () => _HttpClient()..acquire = acquire,
            );
            await clock.run(
              () => harness.run(() async {
                final failed = expectLater(
                  harness.catalog.listModels(),
                  _fails(retire ? 'unavailable' : 'transport'),
                );
                harness.host.reply(0, {'secret': _key});
                await _pump();
                final client = harness.clients.single;
                expect(client.request.closes, 0);
                if (retire) {
                  harness.catalog.close();
                } else {
                  clock.active.single.fire();
                }
                await failed;
                expect(client.forcedCloses, [true]);
                expect(client.request.aborts, 0);
                if (lateFailure) {
                  acquire.completeError(StateError(_privateText));
                } else {
                  acquire.complete(client.request);
                }
                await _pump();
                expect(client.request.aborts, lateFailure ? 0 : 1);
                expect(client.request.headers.values, isEmpty);
                expect(client.request.closes, 0);
                expect(client.response.listens, 0);
                expect(harness.clients, hasLength(1));
                expect(harness.host.requests, hasLength(1));
                expect(clock.active, isEmpty);
              }),
            );
          },
        );
      }
    }

    for (final retire in [false, true]) {
      for (final lateFailure in [false, true]) {
        test(
          '${retire ? 'retirement' : 'opening timeout'} fences late response headers ${lateFailure ? 'failure' : 'success'}',
          () async {
            final headers = Completer<HttpClientResponse>();
            final clock = _Clock();
            final harness = _Harness(
              createClient: () {
                final client = _HttpClient();
                client.request.pendingResponse = headers;
                return client;
              },
            );
            await clock.run(
              () => harness.run(() async {
                final failed = expectLater(
                  harness.catalog.listModels(),
                  _fails(retire ? 'unavailable' : 'transport'),
                );
                harness.host.reply(0, {'secret': _key});
                await _pump();
                final client = harness.clients.single;
                expect(client.request.closes, 1);
                if (retire) {
                  harness.catalog.close();
                } else {
                  clock.active.single.fire();
                }
                await failed;
                expect(client.request.aborts, 1);
                expect(client.forcedCloses, [true]);
                if (lateFailure) {
                  headers.completeError(StateError(_privateText));
                } else {
                  headers.complete(client.response);
                }
                await _pump();
                expect(client.response.statusReads, 0);
                expect(client.response.cancels, lateFailure ? 0 : 1);
                expect(harness.clients, hasLength(1));
                expect(harness.host.requests, hasLength(1));
                expect(clock.active, isEmpty);
              }),
            );
          },
        );
      }
    }

    test(
      'late response cleanup is bounded and contains a late cancellation error',
      () async {
        final headers = Completer<HttpClientResponse>();
        final cleanup = Completer<void>();
        final clock = _Clock();
        final harness = _Harness(
          createClient: () {
            final client = _HttpClient(cancellation: () => cleanup.future);
            client.request.pendingResponse = headers;
            return client;
          },
        );
        await clock.run(
          () => harness.run(() async {
            final failed = expectLater(
              harness.catalog.listModels(),
              _fails('transport'),
            );
            harness.host.reply(0, {'secret': _key});
            await _pump();
            clock.active.single.fire();
            await failed;
            final client = harness.clients.single;
            headers.complete(client.response);
            await _pump();
            expect(client.response.statusReads, 0);
            _expectReleased(client);
            expect(
              clock.active.single.duration,
              harness.catalog.cleanupTimeout,
            );
            clock.active.single.fire();
            await _pump();
            cleanup.completeError(StateError(_privateText));
            await _pump();
            expect(clock.active, isEmpty);
            expect(harness.host.requests, hasLength(1));
            expect(harness.clients, hasLength(1));
          }),
        );
      },
    );

    test(
      'one opening deadline covers acquisition and response headers',
      () async {
        final acquire = Completer<HttpClientRequest>();
        final headers = Completer<HttpClientResponse>();
        final clock = _Clock();
        final harness = _Harness(
          createClient: () {
            final client = _HttpClient()..acquire = acquire;
            client.request.pendingResponse = headers;
            return client;
          },
        );
        await clock.run(
          () => harness.run(() async {
            final failed = expectLater(
              harness.catalog.listModels(),
              _fails('transport'),
            );
            harness.host.reply(0, {'secret': _key});
            await _pump();
            final opening = clock.active.single;
            expect(opening.duration, harness.catalog.responseOpenTimeout);
            acquire.complete(harness.clients.single.request);
            await _pump();
            expect(clock.active.single, same(opening));
            opening.fire();
            await failed;
            headers.completeError(StateError(_privateText));
            await _pump();
            expect(harness.clients.single.forcedCloses, [true]);
          }),
        );
      },
    );

    test(
      'body deadline is absolute despite incoming bytes and valid JSON',
      () async {
        final clock = _Clock();
        final harness = _Harness();
        await clock.run(
          () => harness.run(() async {
            final failed = expectLater(
              harness.catalog.listModels(),
              _fails('transport'),
            );
            harness.host.reply(0, {'secret': _key});
            await _pump();
            expect(clock.timers.first.isActive, isFalse);
            final body = clock.active.single;
            expect(body.duration, harness.catalog.bodyTimeout);
            final client = harness.clients.single;
            client.response.controller.add(utf8.encode(jsonEncode(_list([]))));
            for (var index = 0; index < 5; index++) {
              client.response.controller.add([0x20]);
              await _pump();
              expect(clock.active.single, same(body));
            }
            // A complete JSON value is insufficient: finite body EOF is required.
            body.fire();
            await failed;
            _expectReleased(client);
            expect(client.response.controller.isClosed, isFalse);
            unawaited(client.response.controller.close());
            expect(clock.active, isEmpty);
          }),
        );
      },
    );

    test(
      'successful EOF cancels deadlines and releases the operation once',
      () async {
        final clock = _Clock();
        final harness = _Harness();
        await clock.run(
          () => harness.run(() async {
            final result = harness.catalog.listModels();
            harness.host.reply(0, {'secret': _key});
            await _pump();
            harness.clients.single.response.json(_list([_model('ready')]));
            expect((await result).models.single.modelId, 'ready');
            expect(clock.active, isEmpty);
            harness.catalog.close();
            harness.catalog.close();
            _expectReleased(harness.clients.single);
          }),
        );
      },
    );

    for (final payload in [
      {'secret': _key},
      {'failure': 'storageUnavailable'},
    ]) {
      test(
        'retirement settles pending credentials and fences late ${payload.keys.single}',
        () async {
          final harness = _Harness();
          await harness.run(() async {
            final failed = expectLater(
              harness.catalog.listModels(),
              _fails('unavailable'),
            );
            expect(harness.host.requests, hasLength(1));
            harness.catalog.close();
            harness.catalog.close();
            await failed;
            harness.host.reply(0, payload);
            await _pump();
            await expectLater(
              harness.catalog.listModels(),
              _fails('unavailable'),
            );
            expect(harness.host.requests, hasLength(1));
            expect(harness.clients, isEmpty);
          });
        },
      );
    }

    test(
      'concurrent completion releases only its own HTTP operation',
      () async {
        final harness = _Harness();
        await harness.run(() async {
          final first = harness.catalog.listModels();
          final second = harness.catalog.listModels();
          harness.host.reply(0, {'secret': 'first-key'});
          harness.host.reply(1, {'secret': 'second-key'});
          await _pump();
          harness.clients.first.response.json(_list([_model('first')]));
          expect((await first).models.single.modelId, 'first');
          _expectReleased(harness.clients.first);
          expect(harness.clients.last.forcedCloses, isEmpty);
          expect(harness.clients.last.request.aborts, 0);
          expect(harness.clients.last.response.cancels, 0);
          harness.clients.last.response.json(_list([_model('second')]));
          expect((await second).models.single.modelId, 'second');
          _expectReleased(harness.clients.last);
        });
      },
    );

    test(
      'retirement fences every active body and pending credential call',
      () async {
        final harness = _Harness();
        await harness.run(() async {
          final failures = [
            for (var index = 0; index < 3; index++)
              expectLater(harness.catalog.listModels(), _fails('unavailable')),
          ];
          harness.host.reply(0, {'secret': 'first-key'});
          harness.host.reply(1, {'secret': 'second-key'});
          await _pump();
          harness.clients.first.response.controller.add(
            utf8.encode('{"object":"list"'),
          );
          harness.catalog.close();
          await Future.wait(failures);
          for (final client in harness.clients) {
            _expectReleased(client);
            client.response.json(_list([_model('late')]));
          }
          harness.host.reply(2, {'secret': 'late-key'});
          await _pump();
          expect(harness.clients, hasLength(2));
          await expectLater(
            harness.catalog.listModels(),
            _fails('unavailable'),
          );
          expect(harness.host.requests, hasLength(3));
        });
      },
    );

    for (final success in [false, true]) {
      test(
        'throwing request/client cleanup preserves ${success ? 'success' : 'safe failure'}',
        () async {
          final harness = _Harness(
            createClient: () {
              final client = _HttpClient()
                ..closeFailure = StateError(_privateText);
              client.request.abortFailure = StateError(_privateText);
              return client;
            },
          );
          await harness.run(() async {
            final result = harness.catalog.listModels();
            final failed = success
                ? null
                : expectLater(result, _fails('malformed_response'));
            harness.host.reply(0, {'secret': _key});
            await _pump();
            harness.clients.single.response.json(success ? _list([]) : null);
            if (failed == null) {
              expect((await result).models, isEmpty);
            } else {
              await failed;
            }
            _expectReleased(harness.clients.single);
          });
        },
      );
    }

    for (final retire in [false, true]) {
      test(
        'bounded subscription cleanup preserves ${retire ? 'retirement' : 'HTTP failure'} and contains late error',
        () async {
          final cleanup = Completer<void>();
          final clock = _Clock();
          final harness = _Harness(
            createClient: () => _HttpClient(
              status: retire ? 200 : 401,
              cancellation: () => cleanup.future,
            ),
          );
          await clock.run(
            () => harness.run(() async {
              var settled = false;
              final failed = expectLater(
                harness.catalog.listModels(),
                _fails(retire ? 'unavailable' : 'authentication'),
              ).then((_) => settled = true);
              harness.host.reply(0, {'secret': _key});
              await _pump();
              if (retire) harness.catalog.close();
              await _pump();
              _expectReleased(harness.clients.single);
              expect(settled, isFalse);
              final deadline = clock.active.single;
              expect(deadline.duration, harness.catalog.cleanupTimeout);
              deadline.fire();
              await failed;
              cleanup.completeError(StateError(_privateText));
              await _pump();
              expect(clock.active, isEmpty);
              expect(harness.clients, hasLength(1));
            }),
          );
        },
      );
    }
  });
}

Map<String, Object?> _model(Object? id) => {'object': 'model', 'id': id};
Map<String, Object?> _list(List<Object?> data) => {
  'object': 'list',
  'data': data,
};

const _internalError = {
  'kind': 'response',
  'requestId': 1,
  'ok': false,
  'error': {
    'code': 'internal_error',
    'message': 'The backend request failed unexpectedly.',
    'details': <String, Object?>{},
  },
};

Future<Map<String, Object?>> _dispatch(ModelCatalogService catalog) {
  final dispatcher = ModelCatalogServiceDispatcher(catalog);
  addTearDown(dispatcher.close);
  return dispatcher.dispatch({
    'kind': 'request',
    'requestId': 1,
    'method': modelCatalogServiceListModelsId,
    'payload': <String, Object?>{},
  });
}

Matcher _fails(String code) {
  const messages = {
    'unavailable': 'The configured OpenAI model catalog is unavailable.',
    'unsupported_discovery':
        'Model discovery is unsupported for this configured endpoint.',
    'authentication': 'OpenAI rejected model catalog authentication.',
    'rate_limited': 'OpenAI model discovery is rate limited.',
    'provider_failure': 'OpenAI rejected the model catalog request.',
    'transport':
        'The OpenAI model catalog transport failed or exceeded its deadline.',
    'malformed_response':
        'OpenAI returned an invalid or oversized model catalog.',
  };
  return throwsA(
    isA<ModelCatalogFailure>()
        .having((failure) => failure.code, 'code', code)
        .having((failure) => failure.message, 'message', messages[code])
        .having((failure) => failure.details, 'details', isEmpty)
        .having(
          (failure) => failure.toString(),
          'diagnostics',
          'ModelCatalogFailure($code): ${messages[code]}',
        ),
  );
}

void _expectReleased(_HttpClient client) {
  expect(client.request.aborts, 1);
  expect(client.response.cancels, 1);
  expect(client.forcedCloses, [true]);
  expect(client.urls, hasLength(1));
}

Future<void> _pump() => Future<void>.delayed(Duration.zero);

final class _Harness {
  _Harness({
    String? endpoint,
    String recordId = 'work',
    bool withCredentials = true,
    Future<String> Function()? readCredential,
    this.createClient,
  }) {
    final configuration = OpenAiApiKeyConfiguration.fromRecords(
      AdeleBackendRecords([
        {
          'collection': 'providers',
          'type': openAiApiKeyProviderId,
          'id': recordId,
          'values': {
            'display-name': 'Configured account',
            'endpoint': ?endpoint,
          },
        },
      ]),
    ).single;
    catalog = OpenAiConfiguredModelCatalog(
      configuration: configuration,
      credentials: withCredentials ? host.client : null,
      readCredential: readCredential,
      responseOpenTimeout: const Duration(seconds: 10),
      bodyTimeout: const Duration(seconds: 20),
      cleanupTimeout: const Duration(seconds: 1),
    );
    addTearDown(() {
      catalog.close();
      host.mux.close();
      for (final client in clients) {
        unawaited(client.response.controller.close());
      }
    });
  }

  final host = _CredentialHost();
  final _HttpClient Function()? createClient;
  final clients = <_HttpClient>[];
  late final OpenAiConfiguredModelCatalog catalog;

  Future<void> run(Future<void> Function() body) => HttpOverrides.runZoned(
    body,
    createHttpClient: (_) {
      final client = createClient?.call() ?? _HttpClient();
      clients.add(client);
      return client;
    },
  );
}

final class _CredentialHost {
  _CredentialHost() {
    mux = AdeleHostRequestMultiplexer(send: requests.add);
    client = AdeleCredentialClient(
      hostRequests: mux,
      hostInfrastructureContext: 'generation-grant',
    );
  }

  final requests = <Map<String, Object?>>[];
  late final AdeleHostRequestMultiplexer mux;
  late final AdeleCredentialClient client;

  void reply(int index, Object? payload) => mux.handleResponse({
    'kind': 'hostResponse',
    'requestId': requests[index]['requestId'],
    'ok': true,
    'payload': payload,
  });
}

final class _HttpClient implements HttpClient {
  _HttpClient({int status = 200, FutureOr<void> Function()? cancellation})
    : response = _HttpResponse(status: status, cancellation: cancellation);

  final _HttpResponse response;
  late final request = _HttpRequest(response);
  Completer<HttpClientRequest>? acquire;
  Object? acquireFailure;
  Object? closeFailure;
  final urls = <Uri>[];
  final forcedCloses = <bool>[];

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    urls.add(url);
    if (acquireFailure case final Object failure) throw failure;
    return acquire?.future ?? request;
  }

  @override
  void close({bool force = false}) {
    forcedCloses.add(force);
    if (closeFailure case final Object failure) throw failure;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _HttpRequest implements HttpClientRequest {
  _HttpRequest(this.response);
  final _HttpResponse response;
  Completer<HttpClientResponse>? pendingResponse;
  Object? closeFailure;
  Object? abortFailure;
  var closes = 0;
  var aborts = 0;
  @override
  final _Headers headers = _Headers();
  @override
  bool followRedirects = true;

  @override
  Future<HttpClientResponse> close() async {
    closes++;
    if (closeFailure case final Object failure) throw failure;
    return pendingResponse?.future ?? response;
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborts++;
    if (abortFailure case final Object failure) throw failure;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Headers implements HttpHeaders {
  final values = <String, Object>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name] = value;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _HttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _HttpResponse({
    required this.status,
    FutureOr<void> Function()? cancellation,
  }) {
    controller = StreamController<List<int>>(
      sync: true,
      onCancel: () {
        cancels++;
        return cancellation?.call();
      },
    );
  }

  final int status;
  late final StreamController<List<int>> controller;
  var listens = 0;
  var cancels = 0;
  var statusReads = 0;

  @override
  int get statusCode {
    statusReads++;
    return status;
  }

  void json(Object? payload) => bytes(utf8.encode(jsonEncode(payload)));
  void bytes(List<int> payload) {
    controller.add(payload);
    unawaited(controller.close());
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listens++;
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Control only nonzero deadlines; zero-duration pumps still drain real events.
final class _Clock {
  final timers = <_Deadline>[];
  Iterable<_Deadline> get active => timers.where((timer) => timer.isActive);

  Future<void> run(Future<void> Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        if (duration == Duration.zero) {
          return parent.createTimer(zone, duration, callback);
        }
        final timer = _Deadline(duration, zone.bindCallbackGuarded(callback));
        timers.add(timer);
        return timer;
      },
    ),
  );
}

final class _Deadline implements Timer {
  _Deadline(this.duration, this.callback);
  final Duration duration;
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;

  void fire() {
    expect(isActive, isTrue);
    isActive = false;
    tick++;
    callback();
  }

  @override
  void cancel() => isActive = false;
}
