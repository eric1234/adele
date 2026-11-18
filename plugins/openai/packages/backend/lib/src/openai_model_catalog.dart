import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_model_provider/adele_model_catalog.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';

import 'openai_api_key.dart';
import 'openai_configured_provider.dart';
import 'openai_endpoint.dart';

const int _maximumBodyBytes = 4 * 1024 * 1024;

/// A fresh, finite observation of one configured API-key account, with no cache.
final class OpenAiConfiguredModelCatalog implements ModelCatalogService {
  /// An explicit reader stays bound to its owner's scope, with no startup fallback.
  OpenAiConfiguredModelCatalog({
    required this.configuration,
    AdeleCredentialClient? credentials,
    Future<String> Function()? readCredential,
    this.responseOpenTimeout = const Duration(seconds: 30),
    this.bodyTimeout = const Duration(seconds: 30),
    this.cleanupTimeout = const Duration(seconds: 1),
  }) : _readCredential =
           readCredential ?? (() => configuration.readCredential(credentials));

  final OpenAiApiKeyConfiguration configuration;
  final Future<String> Function() _readCredential;
  final Duration responseOpenTimeout;
  final Duration bodyTimeout;
  final Duration cleanupTimeout;
  final Set<void Function()> _operations = {};
  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    for (final retire in _operations.toList()) {
      retire();
    }
  }

  @override
  Future<ModelCatalogSnapshot> listModels() async {
    if (_closed) throw _unavailable;
    final endpoint = openAiCatalogEndpoint(configuration.endpoint);
    if (endpoint == null) {
      throw const ModelCatalogFailure(
        code: 'unsupported_discovery',
        message: 'Model discovery is unsupported for this configured endpoint.',
      );
    }
    final result = Completer<ModelCatalogSnapshot>();
    HttpClient? client;
    HttpClientRequest? request;
    StreamSubscription<List<int>>? subscription;
    Timer? timer;
    var active = true;

    void fail(Object failure, [StackTrace? stackTrace]) {
      if (!active) return;
      active = false;
      timer?.cancel();
      result.completeError(failure, stackTrace);
    }

    void transportFailure(Object error, StackTrace stackTrace) =>
        fail(switch (error) {
          SocketException() ||
          HttpException() ||
          TlsException() ||
          TimeoutException() => _transport,
          _ => error,
        }, stackTrace);

    void retire() => fail(_unavailable);
    _operations.add(retire);

    Future<void> start() async {
      final String key;
      try {
        key = validateOpenAiApiKey(await _readCredential());
        if (key.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
          throw const FormatException();
        }
      } on Object catch (error, stackTrace) {
        // Authorization, absent/invalid keys and host access failures are not
        // remote authentication rejections: no HTTP has been attempted.
        fail(
          error is AdeleCredentialFailure || error is FormatException
              ? _unavailable
              : error,
          stackTrace,
        );
        return;
      }
      if (!active) return;
      try {
        client = HttpClient();
        timer = Timer(responseOpenTimeout, () => fail(_transport));
        final outgoing = await client!.getUrl(endpoint);
        // Connection acquisition has no request handle until it completes.
        // Timeout/retirement fences even a successful late acquisition.
        if (!active) {
          outgoing.abort();
          return;
        }
        request = outgoing;
        outgoing.followRedirects = false;
        outgoing.headers.set(HttpHeaders.acceptHeader, 'application/json');
        outgoing.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
        final response = await outgoing.close();
        if (!active) {
          await response
              .listen((_) {}, onError: (Object _) {})
              .cancel()
              .timeout(cleanupTimeout);
          return;
        }
        timer?.cancel();
        final status = response.statusCode;
        if (status != HttpStatus.ok) {
          // Error bodies and redirect destinations are never read or surfaced.
          subscription = response.listen((_) {}, onError: (Object _) {});
          fail(switch (status) {
            401 || 403 => const ModelCatalogFailure(
              code: 'authentication',
              message: 'OpenAI rejected model catalog authentication.',
            ),
            429 => const ModelCatalogFailure(
              code: 'rate_limited',
              message: 'OpenAI model discovery is rate limited.',
            ),
            _ => const ModelCatalogFailure(
              code: 'provider_failure',
              message: 'OpenAI rejected the model catalog request.',
            ),
          });
          return;
        }
        final bytes = BytesBuilder(copy: false);
        timer = Timer(bodyTimeout, () => fail(_transport));
        subscription = response.listen(
          (chunk) {
            if (!active) return;
            if (chunk.length > _maximumBodyBytes - bytes.length) {
              fail(_malformed);
              return;
            }
            bytes.add(chunk);
          },
          onError: transportFailure,
          onDone: () {
            if (!active) return;
            try {
              final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
              if (decoded is! Map<String, Object?> ||
                  decoded['object'] != 'list' ||
                  decoded['data'] is! List<Object?>) {
                throw const FormatException();
              }
              final data = decoded['data'] as List<Object?>;
              if (data.length > modelCatalogMaxModels) {
                throw const FormatException();
              }
              final models = <ModelCatalogEntry>[];
              for (final item in data) {
                if (item is! Map<String, Object?> ||
                    item['object'] != 'model' ||
                    item['id'] is! String) {
                  throw const FormatException();
                }
                final id = item['id'] as String;
                // Reject reflected authorization/configuration rather than
                // rewriting an exact ID or publishing private transport data.
                if (id.contains(key) ||
                    id.contains(endpoint.toString()) ||
                    id.contains(
                      configuration.endpoint?.toString() ??
                          openAiDefaultResponsesEndpoint,
                    )) {
                  throw const FormatException();
                }
                models.add(
                  ModelCatalogEntry(
                    modelId: id,
                    displayName: null,
                    description: null,
                  ),
                );
              }
              final snapshot = ModelCatalogSnapshot(models: models);
              active = false;
              timer?.cancel();
              result.complete(snapshot);
            } on FormatException {
              fail(_malformed);
            } on Object catch (error, stackTrace) {
              fail(error, stackTrace);
            }
          },
        );
      } on Object catch (error, stackTrace) {
        transportFailure(error, stackTrace);
      }
    }

    unawaited(start());
    try {
      return await result.future;
    } finally {
      active = false;
      timer?.cancel();
      _operations.remove(retire);
      try {
        request?.abort();
      } on Object {
        // Cleanup must not replace the safe semantic outcome.
      }
      try {
        client?.close(force: true);
      } on Object {
        // The client belongs only to this operation, never a sibling or inference.
      }
      try {
        await subscription?.cancel().timeout(cleanupTimeout);
      } on Object {
        // Late platform cleanup cannot publish data or start another request.
      }
    }
  }
}

const _unavailable = ModelCatalogFailure(
  code: 'unavailable',
  message: 'The configured OpenAI model catalog is unavailable.',
);
const _transport = ModelCatalogFailure(
  code: 'transport',
  message:
      'The OpenAI model catalog transport failed or exceeded its deadline.',
);
const _malformed = ModelCatalogFailure(
  code: 'malformed_response',
  message: 'OpenAI returned an invalid or oversized model catalog.',
);
