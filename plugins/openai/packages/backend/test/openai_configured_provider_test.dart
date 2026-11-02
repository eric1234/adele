import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:openai_model_provider_backend/openai_model_provider_backend.dart';
import 'package:test/test.dart';

void main() {
  group('record configuration', () {
    test(
      'stable public identities are independent of labels and endpoints',
      () {
        final configurations = _configurations([
          _record('work', {'display-name': 'Same label'}),
          _record('personal', {'display-name': 'Same label'}),
          _record('x' * 64, {'display-name': 'Longest record ID'}),
        ]);
        expect(configurations.map((value) => value.providerId.value), [
          'dev.adele.openai.api-key.personal',
          'dev.adele.openai.api-key.work',
          'dev.adele.openai.api-key.${'x' * 64}',
        ]);
        expect(configurations.map((value) => value.configurationContext), [
          'api-key-record:personal',
          'api-key-record:work',
          'api-key-record:${'x' * 64}',
        ]);
        final renamed = _configurations([
          _record('work', {
            'display-name': 'Renamed',
            'endpoint': 'https://example.test/responses',
          }),
        ]).single;
        expect(renamed.providerId, configurations[1].providerId);
        expect(
          renamed.configurationContext,
          configurations[1].configurationContext,
        );
        expect(configurations.first.endpoint, isNull);
        expect(() => configurations.clear(), throwsUnsupportedError);
      },
    );

    test('only exact collection and type materialize providers', () {
      expect(
        _configurations([
          _record('work', {'display-name': 'Work'}),
          {
            ..._record('other', {'display-name': 'Other'}),
            'collection': 'accounts',
          },
          {
            ..._record('peer', {'display-name': 'Peer'}),
            'type': 'dev.adele.peer.api-key',
          },
          {
            ..._record('nested', {'display-name': 'Nested'}),
            'type': '$openAiApiKeyProviderId.nested',
          },
        ]).map((value) => value.recordId),
        ['work'],
      );
    });

    test('diagnostics contain only validated record IDs and fixed codes', () {
      final diagnostics = <(String, String)>[];
      final records = AdeleBackendRecords([
        _record('bad-fields', {'display-name': 'secret-sentinel\n'}),
        _record('bad-endpoint', {
          'display-name': 'Name',
          'endpoint': 'https://secret-sentinel:password@example.test',
        }),
        _record('bad-host', {
          'display-name': 'Name',
          'endpoint': 'https://secret-sentinel_host',
        }),
        _record('healthy', {'display-name': 'Healthy'}),
      ]);
      final configurations = OpenAiApiKeyConfiguration.fromRecords(
        records,
        onRejected: (id, code) => diagnostics.add((id, code)),
      );
      expect(configurations.single.recordId, 'healthy');
      expect(diagnostics, [
        ('bad-fields', 'openai_record_invalid_values'),
        ('bad-endpoint', 'openai_record_invalid_values'),
        ('bad-host', 'openai_record_invalid_configuration'),
      ]);
      expect(diagnostics.toString(), isNot(contains('secret-sentinel')));
    });

    test(
      'duplicate and malformed identities fail rather than selecting a winner',
      () {
        for (final records in [
          [
            _record('work', {'display-name': 'One'}),
            _record('work', {'display-name': 'Two'}),
          ],
          [
            _record('Work', {'display-name': 'One'}),
          ],
          [
            _record('x' * 65, {'display-name': 'One'}),
          ],
          [
            _record('nul', {'display-name': 'One'}),
          ],
        ]) {
          expect(() => _configurations(records), throwsFormatException);
        }
      },
    );

    for (final (index, values) in <Map<String, Object?>>[
      {},
      {'display-name': 1},
      {'display-name': ''},
      {'display-name': '   '},
      {'display-name': 'hidden\nname'},
      {'display-name': 'Name', 'unknown': 'not-a-field'},
      {'display-name': 'Name', 'endpoint': true},
      {'display-name': 'Name', 'endpoint': ''},
      {
        'display-name': 'Name',
        'endpoint': ' https://example.test/v1/responses',
      },
      {
        'display-name': 'Name',
        'endpoint': 'https://example.test/v1/responses ',
      },
    ].indexed) {
      test('invalid fields isolate only their record (case $index)', () {
        final configurations = _configurations([
          _record('before', {'display-name': 'Before'}),
          _record('invalid', values),
          _record('after', {'display-name': 'After'}),
        ]);
        expect(configurations.map((value) => value.recordId), [
          'after',
          'before',
        ]);
      });
    }

    for (final (index, endpoint) in [
      'https://api.openai.com/v1/responses',
      'https://example.test:8443/custom?version=1',
      'https://127.0.0.1/responses',
      'https://[2001:db8::1]/responses',
      'http://localhost:8080/responses',
      'http://127.0.0.2/responses',
      'http://[::1]:8080/responses',
    ].indexed) {
      test('accepts safe endpoint (case $index)', () {
        final configuration = _configurations([
          _record('work', {'display-name': 'Work', 'endpoint': endpoint}),
        ]).single;
        expect(configuration.endpoint, Uri.parse(endpoint));
        final provider = OpenAiModelProvider(
          apiKey: 'fake',
          endpoint: configuration.endpoint,
        );
        provider.close();
      });
    }

    for (final (index, endpoint) in [
      '/relative',
      '//example.test/path',
      'ftp://example.test/path',
      'https:opaque',
      'https:///path',
      'https://user:password@example.test/path',
      'https://@example.test/path',
      'https://example.test/path#fragment',
      'https://example.test/path#',
      'https://bad_host/path',
      'https://bad%20host/path',
      'https://-bad.test/path',
      'https://bad..test/path',
      'https://999.999.999.999/path',
      'https://example.test:0/path',
      'https://example.test:65536/path',
      'http://example.test/path',
      'http://localhost.example.test/path',
      'http://192.168.1.1/path',
      'http://[::]/path',
    ].indexed) {
      test(
        'rejects unsafe endpoint without default or sibling fallback (case $index)',
        () {
          expect(
            _configurations([
              _record('invalid', {
                'display-name': 'Invalid',
                'endpoint': endpoint,
              }),
              _record('healthy', {'display-name': 'Healthy'}),
            ]).map((value) => value.recordId),
            ['healthy'],
          );
          // Uri canonicalizes empty userinfo away; raw record validation above
          // rejects its marker before that information is lost.
          if (endpoint != 'https://@example.test/path') {
            expect(
              () => OpenAiModelProvider(
                apiKey: 'fake',
                endpoint: Uri.parse(endpoint),
              ),
              throwsArgumentError,
            );
          }
        },
      );
    }
  });

  group('credential-backed invocation', () {
    test(
      'construction and unlistened invocation never read or create HTTP clients',
      () async {
        final host = _CredentialHost();
        addTearDown(host.mux.close);
        var clients = 0;
        await HttpOverrides.runZoned(
          () async {
            final provider = _provider(host);
            final stream = provider.invoke(_request());
            await _pump();
            expect(host.requests, isEmpty);
            expect(clients, 0);
            final result = stream.toList();
            expect(host.requests, hasLength(1));
            expect(host.requests.single['hostContextKind'], 'infrastructure');
            expect(host.requests.single['hostContext'], 'generation-grant');
            expect(
              host.requests.single['serviceId'],
              backendCredentialServiceId,
            );
            expect(host.requests.single['payload'], {
              'collection': 'providers',
              'recordType': openAiApiKeyProviderId,
              'recordId': 'work',
              'slot': 'api-key',
            });
            expect(() => stream.listen((_) {}), throwsStateError);
            host.reply(0, {'failure': 'notConfigured'});
            expect(
              (await result).single.terminal!.failure!.providerCode,
              'openai_credential_not_configured',
            );
            expect(clients, 0);
          },
          createHttpClient: (_) {
            clients++;
            return _HttpClient();
          },
        );
      },
    );

    const mappings =
        <
          AdeleCredentialFailureKind,
          (ModelProviderFailureKind, String, String)
        >{
          AdeleCredentialFailureKind.notAuthorized: (
            ModelProviderFailureKind.permission,
            'not_authorized',
            'Credential access is not authorized for this OpenAI provider.',
          ),
          AdeleCredentialFailureKind.notConfigured: (
            ModelProviderFailureKind.unavailable,
            'not_configured',
            'No API key is configured for this OpenAI provider.',
          ),
          AdeleCredentialFailureKind.missingLocally: (
            ModelProviderFailureKind.unavailable,
            'missing_locally',
            'The configured OpenAI API key is missing from local storage.',
          ),
          AdeleCredentialFailureKind.storageUnavailable: (
            ModelProviderFailureKind.unavailable,
            'storage_unavailable',
            'Credential storage is unavailable for this OpenAI provider.',
          ),
          AdeleCredentialFailureKind.invalidCredentialBinding: (
            ModelProviderFailureKind.unavailable,
            'invalid_binding',
            'The configured OpenAI credential binding is invalid.',
          ),
          AdeleCredentialFailureKind.reconciliationRequired: (
            ModelProviderFailureKind.unavailable,
            'reconciliation_required',
            'The configured OpenAI credential requires reconciliation in Settings.',
          ),
          AdeleCredentialFailureKind.staleConfiguration: (
            ModelProviderFailureKind.unavailable,
            'stale_configuration',
            'The OpenAI configuration changed; restart the backend before invoking it.',
          ),
          AdeleCredentialFailureKind.generationUnavailable: (
            ModelProviderFailureKind.unavailable,
            'generation_unavailable',
            'This OpenAI backend generation cannot access credentials.',
          ),
          AdeleCredentialFailureKind.credentialAccessFailed: (
            ModelProviderFailureKind.unavailable,
            'access_failed',
            'Credential access failed for this OpenAI provider.',
          ),
        };
    for (final kind in AdeleCredentialFailureKind.values) {
      test('maps $kind to fixed safe provider failure without HTTP', () async {
        final host = _CredentialHost();
        addTearDown(host.mux.close);
        await HttpOverrides.runZoned(() async {
          final result = _provider(host).invoke(_request()).toList();
          host.reply(0, {'failure': kind.name});
          final terminal = (await result).single.terminal!;
          final expected = mappings[kind]!;
          expect(terminal.settlement, ModelProviderSettlement.failed);
          expect(terminal.failure!.kind, expected.$1);
          expect(
            terminal.failure!.providerCode,
            'openai_credential_${expected.$2}',
          );
          expect(terminal.failure!.providerMessage, expected.$3);
          expect(terminal.failure!.providerDetails, isEmpty);
          expect(terminal.requestId, isNull);
        }, createHttpClient: (_) => throw StateError('HTTP must not start'));
      });
    }

    for (final (index, payload) in <Object?>[
      {'secret': 'sentinel-secret', 'raw': 'sentinel-native-error'},
      {'failure': 'sentinel-secret'},
      {'secret': ''},
      {'secret': '\u0000sentinel-secret'},
      'sentinel-secret',
    ].indexed) {
      test(
        'malformed credential response is fixed and redacted (case $index)',
        () async {
          final host = _CredentialHost();
          addTearDown(host.mux.close);
          final result = _provider(host).invoke(_request()).toList();
          host.reply(0, payload);
          final failure = (await result).single.terminal!.failure!;
          expect(failure.providerCode, 'openai_credential_access_failed');
          expect(
            failure.providerMessage,
            mappings[AdeleCredentialFailureKind.credentialAccessFailed]!.$3,
          );
          expect(failure.providerDetails, isEmpty);
        },
      );
    }

    test('a missing grant fails explicitly without a host read', () async {
      final provider = OpenAiConfiguredModelProvider(
        configuration: _configuration(),
        credentials: null,
      );
      expect(
        (await provider.invoke(_request()).single)
            .terminal!
            .failure!
            .providerCode,
        'openai_credential_generation_unavailable',
      );
    });

    test(
      'invalid delivered API key does not allocate HTTP or leak the value',
      () async {
        final host = _CredentialHost();
        addTearDown(host.mux.close);
        var allocations = 0;
        await HttpOverrides.runZoned(
          () async {
            final result = _provider(host).invoke(_request()).toList();
            host.reply(0, {'secret': 'sentinel-secret\ninvalid'});
            final failure = (await result).single.terminal!.failure!;
            expect(failure.kind, ModelProviderFailureKind.unavailable);
            expect(failure.providerCode, 'openai_credential_invalid_api_key');
            expect(
              failure.providerMessage,
              'The configured OpenAI API key is invalid.',
            );
            expect(allocations, 0);
          },
          createHttpClient: (_) {
            allocations++;
            return _HttpClient();
          },
        );
      },
    );

    test(
      'each invocation reads a fresh key and owns and closes a distinct client',
      () async {
        final host = _CredentialHost();
        addTearDown(host.mux.close);
        final clients = <_HttpClient>[];
        await HttpOverrides.runZoned(
          () async {
            final provider = _provider(host);
            for (var i = 0; i < 2; i++) {
              final result = provider.invoke(_request()).toList();
              expect(host.requests, hasLength(i + 1));
              host.reply(i, {'secret': 'fresh-key-$i'});
              await _pump();
              final client = clients[i];
              expect(
                client.request.headers.value(HttpHeaders.authorizationHeader),
                'Bearer fresh-key-$i',
              );
              expect(
                client.endpoint,
                Uri.parse('https://api.openai.com/v1/responses'),
              );
              expect(client.request.followRedirects, isFalse);
              client.response.complete();
              expect(
                (await result).last.terminal!.settlement,
                ModelProviderSettlement.completed,
              );
              expect(client.closes, 1);
            }
            expect(clients, hasLength(2));
            expect(identical(clients[0], clients[1]), isFalse);
            final denied = provider.invoke(_request()).toList();
            expect(host.requests, hasLength(3));
            host.reply(2, {'failure': 'notConfigured'});
            expect(
              (await denied).single.terminal!.failure!.providerCode,
              'openai_credential_not_configured',
            );
            expect(clients, hasLength(2));
          },
          createHttpClient: (_) {
            final client = _HttpClient();
            clients.add(client);
            return client;
          },
        );
      },
    );

    test(
      'cancellation before credential completion fences late success and failure',
      () async {
        final host = _CredentialHost();
        addTearDown(host.mux.close);
        var allocations = 0;
        await HttpOverrides.runZoned(
          () async {
            for (final payload in [
              {'secret': 'late-key'},
              {'failure': 'storageUnavailable'},
            ]) {
              final events = <ModelProviderEvent>[];
              final subscription = _provider(
                host,
              ).invoke(_request()).listen(events.add);
              await subscription.cancel();
              host.reply(host.requests.length - 1, payload);
              await _pump();
              expect(events, isEmpty);
              expect(allocations, 0);
            }
          },
          createHttpClient: (_) {
            allocations++;
            return _HttpClient();
          },
        );
      },
    );

    test(
      'transport retry retains one credential read and temporary client',
      () async {
        final host = _CredentialHost();
        addTearDown(host.mux.close);
        final retryResponse = _HttpResponse();
        final client = _HttpClient(retryResponse: retryResponse);
        var allocations = 0;
        await HttpOverrides.runZoned(
          () async {
            final result = _provider(host).invoke(_request()).toList();
            host.reply(0, {'secret': 'retry-sentinel-key'});
            await _pump();
            client.response.controller.addError(
              const SocketException(
                'retry-sentinel-key private socket message',
              ),
            );
            await client.secondSend.future.timeout(const Duration(seconds: 2));
            await _pump();
            expect(client.request.aborts, 1);
            expect(client.response.cancels, 1);
            expect(client.closes, 0);
            expect(host.requests, hasLength(1));
            expect(allocations, 1);
            expect(
              client.retryRequest.headers.value(
                HttpHeaders.authorizationHeader,
              ),
              'Bearer retry-sentinel-key',
            );
            retryResponse.complete();
            final events = await result;
            expect(events, hasLength(1));
            expect(
              events.single.terminal!.settlement,
              ModelProviderSettlement.completed,
            );
            expect(client.sends, 2);
            expect(client.closes, 1);
            expect(retryResponse.cancels, 1);
          },
          createHttpClient: (_) {
            allocations++;
            return client;
          },
        );
      },
    );

    test(
      'pause before key propagates to HTTP and resume restores delivery',
      () async {
        final host = _CredentialHost();
        addTearDown(host.mux.close);
        final client = _HttpClient();
        await HttpOverrides.runZoned(() async {
          final events = <ModelProviderEvent>[];
          final done = Completer<void>();
          final subscription = _provider(
            host,
          ).invoke(_request()).listen(events.add, onDone: done.complete);
          subscription.pause();
          host.reply(0, {'secret': 'key'});
          await _pump();
          expect(client.response.pauses, 1);
          client.response.delta('held');
          await _pump();
          expect(events, isEmpty);
          subscription.resume();
          await _pump();
          expect(client.response.resumes, 1);
          expect(events.single.observation!.textDelta, 'held');
          subscription.pause();
          expect(client.response.pauses, 2);
          subscription.resume();
          expect(client.response.resumes, 2);
          client.response.complete();
          await done.future;
          expect(client.closes, 1);
        }, createHttpClient: (_) => client);
      },
    );

    test(
      'active cancellation propagates and releases only its invocation',
      () async {
        final host = _CredentialHost();
        addTearDown(host.mux.close);
        final clients = <_HttpClient>[];
        await HttpOverrides.runZoned(
          () async {
            final provider = _provider(host);
            final events = <ModelProviderEvent>[];
            final first = provider.invoke(_request()).listen(events.add);
            final second = provider.invoke(_request()).toList();
            host.reply(0, {'secret': 'first-key'});
            host.reply(1, {'secret': 'second-key'});
            await _pump();
            await first.cancel();
            expect(clients.first.request.aborts, 1);
            expect(clients.first.response.cancels, 1);
            expect(clients.first.closes, 1);
            expect(clients.last.closes, 0);
            clients.last.response.complete();
            expect(
              (await second).single.terminal!.settlement,
              ModelProviderSettlement.completed,
            );
            expect(clients.last.closes, 1);
            expect(events, isEmpty);
          },
          createHttpClient: (_) {
            final client = _HttpClient();
            clients.add(client);
            return client;
          },
        );
      },
    );

    test(
      'failed HTTP stream closes its owned client with safe diagnostics',
      () async {
        final host = _CredentialHost();
        addTearDown(host.mux.close);
        final client = _HttpClient();
        await HttpOverrides.runZoned(() async {
          final result = _provider(host).invoke(_request()).toList();
          host.reply(0, {'secret': 'sentinel-key'});
          await _pump();
          client.response.controller.addError(
            StateError('sentinel-key native error'),
          );
          final failure = (await result).single.terminal!.failure!;
          expect(failure.providerCode, 'stream_transport');
          expect(failure.providerMessage, 'The OpenAI response stream failed.');
          expect(client.closes, 1);
        }, createHttpClient: (_) => client);
      },
    );

    test(
      'HTTP setup exception closes client without exposing secret exception',
      () async {
        final host = _CredentialHost();
        addTearDown(host.mux.close);
        final client = _HttpClient()
          ..setupFailure = StateError('sentinel-key native error');
        await HttpOverrides.runZoned(() async {
          final result = _provider(host).invoke(_request()).toList();
          host.reply(0, {'secret': 'sentinel-key'});
          final failure = (await result).single.terminal!.failure!;
          expect(failure.providerCode, 'transport_error');
          expect(failure.providerMessage, 'The OpenAI transport failed.');
          expect(client.closes, 1);
        }, createHttpClient: (_) => client);
      },
    );

    test('mux closure settles a pending read safely without HTTP', () async {
      final host = _CredentialHost();
      final result = _provider(host).invoke(_request()).toList();
      host.mux.close();
      final failure = (await result).single.terminal!.failure!;
      expect(failure.providerCode, 'openai_credential_access_failed');
      host.reply(0, {'secret': 'late-secret'});
    });

    test('provider semantic failure redacts the delivered API key', () async {
      final host = _CredentialHost();
      addTearDown(host.mux.close);
      final client = _HttpClient();
      await HttpOverrides.runZoned(() async {
        final result = _provider(host).invoke(_request()).toList();
        host.reply(0, {'secret': 'sentinel-key'});
        await _pump();
        client.response.send({
          'type': 'error',
          'code': 'sentinel-key',
          'message': 'Rejected sentinel-key',
        });
        final failure = (await result).single.terminal!.failure!;
        expect(failure.providerCode, isNot(contains('sentinel-key')));
        expect(failure.providerMessage, isNot(contains('sentinel-key')));
        expect(client.closes, 1);
      }, createHttpClient: (_) => client);
    });
  });
}

Map<String, Object?> _record(String id, Map<String, Object?> values) => {
  'collection': 'providers',
  'type': openAiApiKeyProviderId,
  'id': id,
  'values': values,
};

List<OpenAiApiKeyConfiguration> _configurations(
  List<Map<String, Object?>> records,
) => OpenAiApiKeyConfiguration.fromRecords(AdeleBackendRecords(records));

OpenAiApiKeyConfiguration _configuration() => _configurations([
  _record('work', {'display-name': 'Work'}),
]).single;

OpenAiConfiguredModelProvider _provider(_CredentialHost host) =>
    OpenAiConfiguredModelProvider(
      configuration: _configuration(),
      credentials: host.client,
    );

ModelProviderRequest _request() => ModelProviderRequest(
  model: 'test-model',
  instructions: '',
  input: const [],
  tools: const [],
  toolChoice: ModelProviderToolChoice.auto,
  maxOutputTokens: null,
  providerOptions: const {},
  nativeState: null,
  affinity: null,
);

Future<void> _pump() => Future<void>.delayed(Duration.zero);

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
  _HttpClient({this.retryResponse});
  final response = _HttpResponse();
  final _HttpResponse? retryResponse;
  late final request = _HttpRequest(response);
  late final retryRequest = _HttpRequest(retryResponse!);
  final secondSend = Completer<void>();
  var sends = 0;
  Uri? endpoint;
  Object? setupFailure;
  var closes = 0;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    endpoint = url;
    sends++;
    if (sends == 2 && retryResponse != null) {
      secondSend.complete();
      return retryRequest;
    }
    if (setupFailure case final Object failure) throw failure;
    return request;
  }

  @override
  void close({bool force = false}) => closes++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _HttpRequest implements HttpClientRequest {
  _HttpRequest(this.response);
  final _HttpResponse response;
  @override
  final headers = _Headers();
  @override
  bool followRedirects = true;
  var aborts = 0;

  @override
  void write(Object? object) {}

  @override
  Future<HttpClientResponse> close() async => response;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) => aborts++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Headers implements HttpHeaders {
  final values = <String, Object>{};
  @override
  ContentType? contentType;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name] = value;

  @override
  String? value(String name) => values[name] as String?;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _HttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _HttpResponse() {
    controller = StreamController<List<int>>(
      sync: true,
      onPause: () => pauses++,
      onResume: () => resumes++,
      onCancel: () => cancels++,
    );
  }

  late final StreamController<List<int>> controller;
  var pauses = 0;
  var resumes = 0;
  var cancels = 0;
  @override
  final headers = _Headers();
  @override
  int get statusCode => 200;

  void send(Map<String, Object?> event) =>
      controller.add(utf8.encode('data: ${jsonEncode(event)}\n\n'));
  void delta(String text) =>
      send({'type': 'response.output_text.delta', 'delta': text});
  void complete() => send({
    'type': 'response.completed',
    'response': {'id': 'test-response'},
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
