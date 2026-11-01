import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';

import '../openai_model_provider_backend.dart';
import 'openai_endpoint.dart';

/// Nonsecret configuration captured for one record-backed provider generation.
final class OpenAiApiKeyConfiguration {
  OpenAiApiKeyConfiguration._({
    required this.recordId,
    required this.displayName,
    required this.endpoint,
  }) : providerId = ProviderId('$openAiApiKeyProviderId.$recordId'),
       configurationContext = 'api-key-record:$recordId' {
    adeleValidateConfigurationContext(configurationContext);
  }

  final String recordId;
  final ProviderId providerId;
  final String configurationContext;
  final String displayName;
  final Uri? endpoint;

  /// Structural validation belongs to backend support; plugin semantics are
  /// checked independently so one unusable record cannot suppress its siblings.
  static List<OpenAiApiKeyConfiguration> fromRecords(
    AdeleBackendRecords records, {
    void Function(String recordId, String code)? onRejected,
  }) {
    final configurations = <OpenAiApiKeyConfiguration>[];
    for (final record in records.records) {
      if (record['collection'] != 'providers' ||
          record['type'] != openAiApiKeyProviderId) {
        continue;
      }
      final values = record['values'] as Map<String, Object>;
      final name = values['display-name'];
      final endpoint = values['endpoint'];
      if (name is! String ||
          name.trim().isEmpty ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
          values.keys.any(
            (key) => key != 'display-name' && key != 'endpoint',
          ) ||
          (values.containsKey('endpoint') &&
              (endpoint is! String ||
                  endpoint.isEmpty ||
                  RegExp(r'^[^:]+://[^/?#]*@').hasMatch(endpoint) ||
                  RegExp(r'\s|[\x00-\x1f\x7f]').hasMatch(endpoint)))) {
        onRejected?.call(
          record['id'] as String,
          'openai_record_invalid_values',
        );
        continue;
      }
      try {
        configurations.add(
          OpenAiApiKeyConfiguration._(
            recordId: record['id'] as String,
            displayName: name,
            endpoint: endpoint == null
                ? null
                : validateOpenAiEndpoint(Uri.parse(endpoint as String)),
          ),
        );
      } on Object {
        // Do not echo supplied values, or replace an invalid endpoint by default.
        onRejected?.call(
          record['id'] as String,
          'openai_record_invalid_configuration',
        );
      }
    }
    configurations.sort((a, b) => a.recordId.compareTo(b.recordId));
    return List.unmodifiable(configurations);
  }
}

/// Resolves one fresh host-authorized key only when an invocation is listened to.
/// Each invocation owns its temporary provider and HTTP client, not the host mux.
final class OpenAiConfiguredModelProvider implements ModelProviderService {
  OpenAiConfiguredModelProvider({
    required this.configuration,
    required AdeleCredentialClient? credentials,
  }) : _credentials = credentials;

  final OpenAiApiKeyConfiguration configuration;
  final AdeleCredentialClient? _credentials;

  @override
  Stream<ModelProviderEvent> invoke(ModelProviderRequest request) {
    late final StreamController<ModelProviderEvent> controller;
    OpenAiModelProvider? provider;
    StreamSubscription<ModelProviderEvent>? subscription;
    Future<void>? releasing;
    var cancelled = false;
    var settled = false;

    Future<void> release() => releasing ??= () async {
      final active = subscription;
      subscription = null;
      try {
        await active?.cancel();
      } finally {
        provider?.close();
        provider = null;
      }
    }();

    void fail(ModelProviderFailure failure) {
      if (cancelled || settled) return;
      settled = true;
      controller.add(
        ModelProviderEvent(
          kind: ModelProviderEventKind.terminal,
          observation: null,
          output: null,
          terminal: ModelProviderTerminal(
            settlement: ModelProviderSettlement.failed,
            incompleteReason: null,
            failure: failure,
            providerStopReason: 'failed',
            usage: null,
            effectiveModel: null,
            responseId: null,
            requestId: null,
            nativeState: null,
            affinityState: null,
          ),
        ),
      );
      unawaited(release().then((_) => controller.close()));
    }

    Future<void> start() async {
      final String key;
      try {
        final credentials = _credentials;
        if (credentials == null) {
          throw const AdeleCredentialFailure(
            AdeleCredentialFailureKind.generationUnavailable,
          );
        }
        key = await credentials.readCredential(
          collection: 'providers',
          recordType: openAiApiKeyProviderId,
          recordId: configuration.recordId,
          slot: 'api-key',
        );
      } on AdeleCredentialFailure catch (failure) {
        fail(_credentialFailure(failure.kind));
        return;
      } on Object {
        fail(
          _credentialFailure(AdeleCredentialFailureKind.credentialAccessFailed),
        );
        return;
      }
      // Credential reads cannot cancel an OS prompt. Cancellation still fences
      // construction and HTTP, including a successful late credential delivery.
      if (cancelled) return;
      try {
        provider = OpenAiModelProvider(
          apiKey: key,
          endpoint: configuration.endpoint,
        );
      } on FormatException {
        fail(
          ModelProviderFailure(
            kind: ModelProviderFailureKind.unavailable,
            providerCode: 'openai_credential_invalid_api_key',
            providerMessage: 'The configured OpenAI API key is invalid.',
            providerDetails: const {},
          ),
        );
        return;
      } on Object {
        fail(_invocationFailure());
        return;
      }
      try {
        subscription = provider!
            .invoke(request)
            .listen(
              (event) {
                if (cancelled || settled) return;
                if (event.kind == ModelProviderEventKind.terminal) {
                  settled = true;
                }
                controller.add(event);
              },
              onError: (Object _, StackTrace _) => fail(_invocationFailure()),
              onDone: () =>
                  unawaited(release().then((_) => controller.close())),
            );
        if (controller.isPaused) subscription!.pause();
      } on Object {
        fail(_invocationFailure());
      }
    }

    controller = StreamController<ModelProviderEvent>(
      onListen: () => unawaited(start()),
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        cancelled = true;
        return release();
      },
    );
    return controller.stream;
  }
}

ModelProviderFailure _invocationFailure() => ModelProviderFailure(
  kind: ModelProviderFailureKind.transport,
  providerCode: 'openai_configured_invocation_failed',
  providerMessage: 'The configured OpenAI invocation failed.',
  providerDetails: const {},
);

ModelProviderFailure _credentialFailure(AdeleCredentialFailureKind kind) {
  final (failureKind, code, message) = switch (kind) {
    AdeleCredentialFailureKind.notAuthorized => (
      ModelProviderFailureKind.permission,
      'not_authorized',
      'Credential access is not authorized for this OpenAI provider.',
    ),
    AdeleCredentialFailureKind.notConfigured => (
      ModelProviderFailureKind.unavailable,
      'not_configured',
      'No API key is configured for this OpenAI provider.',
    ),
    AdeleCredentialFailureKind.missingLocally => (
      ModelProviderFailureKind.unavailable,
      'missing_locally',
      'The configured OpenAI API key is missing from local storage.',
    ),
    AdeleCredentialFailureKind.storageUnavailable => (
      ModelProviderFailureKind.unavailable,
      'storage_unavailable',
      'Credential storage is unavailable for this OpenAI provider.',
    ),
    AdeleCredentialFailureKind.invalidCredentialBinding => (
      ModelProviderFailureKind.unavailable,
      'invalid_binding',
      'The configured OpenAI credential binding is invalid.',
    ),
    AdeleCredentialFailureKind.reconciliationRequired => (
      ModelProviderFailureKind.unavailable,
      'reconciliation_required',
      'The configured OpenAI credential requires reconciliation in Settings.',
    ),
    AdeleCredentialFailureKind.staleConfiguration => (
      ModelProviderFailureKind.unavailable,
      'stale_configuration',
      'The OpenAI configuration changed; restart the backend before invoking it.',
    ),
    AdeleCredentialFailureKind.generationUnavailable => (
      ModelProviderFailureKind.unavailable,
      'generation_unavailable',
      'This OpenAI backend generation cannot access credentials.',
    ),
    AdeleCredentialFailureKind.credentialAccessFailed => (
      ModelProviderFailureKind.unavailable,
      'access_failed',
      'Credential access failed for this OpenAI provider.',
    ),
  };
  return ModelProviderFailure(
    kind: failureKind,
    providerCode: 'openai_credential_$code',
    providerMessage: message,
    providerDetails: const {},
  );
}
