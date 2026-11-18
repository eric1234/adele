import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_provider/adele_model_catalog.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';

import '../openai_model_provider_backend.dart';

/// Host control only: never advertised as a Capability or a frontend service.
const openAiConfigurationServiceId = 'dev.adele.openai.configuration';

/// Owns immutable configured revisions, not Settings or provider selection.
final class OpenAiConfiguredProviders {
  OpenAiConfiguredProviders({
    required this.router,
    required this.defaultConfigurationContext,
    required this.credentials,
    required this.publisher,
    required List<OpenAiApiKeyConfiguration> configurations,
  }) {
    for (final configuration in configurations) {
      _current[configuration.recordId] = _create(configuration);
    }
    initialExposures = List.unmodifiable([
      for (final revision in _current.values) ...revision.exposures,
    ]);
  }

  final AdeleConfigurationContextRouter router;
  final String defaultConfigurationContext;
  final AdeleCredentialClient? credentials;
  final AdeleCapabilityPublisher? publisher;
  late final List<AdeleCapabilityExposure> initialExposures;
  final _current = <String, _ConfiguredRevision>{};
  final _revisions = <_ConfiguredRevision>{};
  final _draining = <_ConfiguredRevision>{};
  final _scopes = <_CapturedConfiguration>{};
  Future<void> _serial = Future.value();
  Future<void>? _closing;
  bool _stopping = false;
  bool _publicationUncertain = false;
  bool _cleanupFailed = false;
  int _pending = 0;

  // Local lifecycle evidence, never included in control responses.
  int get activeRevisionCount => _current.length;
  int get drainingRevisionCount => _draining.length;
  int get retainedCaptureCount => _scopes.length;

  /// Called asynchronously by the receive loop so reverse replies keep flowing.
  Future<void> handleControl(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?>) send,
  ) async {
    final payload = command['payload'];
    final valid =
        command['kind'] == 'request' &&
        command['serviceId'] == openAiConfigurationServiceId &&
        command['configurationContext'] == defaultConfigurationContext &&
        !command.containsKey('hostInvocationContext') &&
        command['method'] == 'refreshConfiguredProvider' &&
        payload is Map &&
        payload.length == 1 &&
        payload.containsKey('recordId');
    final result = valid
        ? await refreshConfiguredProvider(payload['recordId'])
        : _result('failed', 'invalid_request');
    send({
      'kind': command['kind'] == 'streamOpen' ? 'streamFailure' : 'response',
      'requestId': command['requestId'],
      if (command['kind'] != 'streamOpen') 'ok': true,
      if (command['kind'] != 'streamOpen') 'payload': result,
      if (command['kind'] == 'streamOpen')
        'error': {
          'code': 'invalid_request',
          'message': 'OpenAI configuration control requires a unary request.',
        },
    });
  }

  Future<Map<String, Object?>> refreshConfiguredProvider(Object? recordId) {
    try {
      // Reuse the public bounded, portable record-identity grammar.
      AdeleBackendRecords([
        {
          'collection': 'providers',
          'type': openAiApiKeyProviderId,
          'id': recordId,
          'values': <String, Object>{},
        },
      ]);
    } on Object {
      return Future.value(_result('failed', 'invalid_record_id'));
    }
    if (_stopping) return Future.value(_result('unavailable', 'shutdown'));
    if (_pending >= 32) {
      return Future.value(_result('unavailable', 'refresh_capacity'));
    }
    _pending++;
    final result = _serial.then((_) => _refresh(recordId as String));
    _serial = result.then<void>((_) {}).whenComplete(() => _pending--);
    return result;
  }

  Future<Map<String, Object?>> _refresh(String recordId) async {
    if (_stopping) return _result('unavailable', 'shutdown');
    if (_publicationUncertain) {
      return _result('unavailable', 'publication_outcome_unknown');
    }
    if (credentials == null || publisher == null) {
      return _result('unavailable', 'host_grants_unavailable');
    }
    _CapturedConfiguration? scope;
    _ConfiguredRevision? candidate;
    final old = _current[recordId];
    var changingPublication = false;
    var status = 'failed';
    var code = 'refresh_failed';
    try {
      final capture = await credentials!.captureCurrentConfiguration();
      scope = _CapturedConfiguration(capture);
      _scopes.add(scope);
      if (_stopping) throw const _RefreshOutcome('unavailable', 'shutdown');
      final records = capture.records
          .where(
            (record) =>
                record['collection'] == 'providers' && record['id'] == recordId,
          )
          .toList();
      if (records.isEmpty && !capture.isComplete) {
        throw const _RefreshOutcome('failed', 'incomplete_observation');
      }
      if (records.isNotEmpty) {
        final configurations = OpenAiApiKeyConfiguration.fromRecords(
          AdeleBackendRecords(records),
        );
        if (configurations.length != 1) {
          throw const _RefreshOutcome('failed', 'invalid_configuration');
        }
        // Equality of ordinary values cannot establish unchanged credentials.
        candidate = _create(configurations.single, scope: scope);
      } else if (old == null) {
        throw const _RefreshOutcome('noChange', 'already_absent');
      }

      // Adoption is lazy and preserves original exact registrations. A rejected
      // adoption must never take down a healthy startup route.
      if (old != null && old.publication == null) {
        old.publication = await publisher!.adoptAdvertised(old.exposures);
      }
      if (_stopping) throw const _RefreshOutcome('unavailable', 'shutdown');
      changingPublication = true;
      if (candidate == null) {
        await old!.publication!.retire();
        _current.remove(recordId);
        _retire(old);
        code = 'retired';
      } else {
        candidate.publication = old == null
            ? await publisher!.publish(candidate.exposures)
            : await old.publication!.replace(candidate.exposures);
        _current[recordId] = candidate;
        candidate =
            null; // The current map now owns the revision's scope lease.
        if (old != null) _retire(old);
        code = old == null ? 'added' : 'replaced';
      }
      status = _stopping ? 'unavailable' : 'applied';
      if (_stopping) code = 'shutdown';
    } on _RefreshOutcome catch (outcome) {
      status = outcome.status;
      code = outcome.code;
    } on AdeleCredentialFailure catch (failure) {
      status =
          failure.kind == AdeleCredentialFailureKind.generationUnavailable ||
              failure.kind == AdeleCredentialFailureKind.notAuthorized
          ? 'unavailable'
          : 'failed';
      code = _failureCode('credential_capture', failure.kind);
    } on AdeleCapabilityPublicationFailure catch (failure) {
      code = _failureCode('publication', failure.kind);
      final unknown =
          failure.kind == AdeleCapabilityPublicationFailureKind.outcomeUnknown;
      if (unknown) {
        // There is no authoritative reconciliation API for a lost publication
        // acknowledgement. Fence further mutations until generation shutdown.
        _publicationUncertain = true;
      }
      if (changingPublication &&
          old != null &&
          (old.publication!.isRetired || unknown)) {
        _current.remove(recordId);
        _retire(old);
      }
      status =
          unknown ||
              failure.kind ==
                  AdeleCapabilityPublicationFailureKind
                      .replacementUnavailable ||
              failure.kind ==
                  AdeleCapabilityPublicationFailureKind.staleGroup ||
              failure.kind ==
                  AdeleCapabilityPublicationFailureKind.generationUnavailable ||
              failure.kind == AdeleCapabilityPublicationFailureKind.notReady ||
              failure.kind ==
                  AdeleCapabilityPublicationFailureKind.notAuthorized
          ? 'unavailable'
          : 'failed';
    } on Object {
      // Neither configuration values nor native exceptions cross this boundary.
      code = 'refresh_failed';
    } finally {
      // An uncertain publication may already have admitted candidate work. Its
      // route must drain independently, just like the superseded revision.
      if (candidate != null) unawaited(_retire(candidate));
      if (scope != null) await _releaseScope(scope);
    }
    return _result(
      _stopping ? 'unavailable' : status,
      _stopping ? 'shutdown' : code,
    );
  }

  _ConfiguredRevision _create(
    OpenAiApiKeyConfiguration configuration, {
    _CapturedConfiguration? scope,
  }) {
    Future<String> read() => scope == null
        ? configuration.readCredential(credentials)
        : scope.capture.readCredential(
            collection: 'providers',
            recordType: openAiApiKeyProviderId,
            recordId: configuration.recordId,
            slot: 'api-key',
          );
    final inference = OpenAiConfiguredModelProvider(
      configuration: configuration,
      readCredential: read,
    );
    final catalog = OpenAiConfiguredModelCatalog(
      configuration: configuration,
      readCredential: read,
    );
    final route = router.registerContext(
      services: {
        modelProviderServiceId: ModelProviderServiceDispatcher(inference),
        modelCatalogServiceId: ModelCatalogServiceDispatcher(catalog),
      },
    );
    scope?.retain();
    final revision = _ConfiguredRevision(
      configuration,
      scope,
      inference,
      catalog,
      route,
    );
    _revisions.add(revision);
    return revision;
  }

  Future<void> _retire(_ConfiguredRevision revision) {
    if (revision.drain != null) return revision.drain!;
    _draining.add(revision);
    // Retirement fences admission synchronously, but never waits in the refresh
    // queue for an admitted HTTP operation or a paused stream to finish.
    return revision.drain = revision.route
        .retire()
        .catchError((Object _) {
          _cleanupFailed = true;
        })
        .then((_) async {
          revision.catalog.close();
          if (revision.scope case final scope?) await _releaseScope(scope);
          _draining.remove(revision);
          _revisions.remove(revision);
        });
  }

  Future<void> _releaseScope(_CapturedConfiguration scope) async {
    if (!scope.releaseOwner()) return;
    try {
      await scope.capture.release();
    } on Object {
      _cleanupFailed = true;
    } finally {
      _scopes.remove(scope);
    }
  }

  Map<String, Object?> _result(String status, String code) => {
    'status': status,
    'code': code,
    'cleanupPending': _draining.isNotEmpty || _cleanupFailed,
  };

  /// The receive loop must revoke its host multiplexer before awaiting this.
  /// Shutdown, unlike replacement, cancels streams and pending catalog results.
  Future<void> close() {
    if (_closing != null) return _closing!;
    _stopping = true;
    for (final revision in _revisions) {
      revision.catalog.close();
    }
    return _closing = () async {
      await router.close();
      await _serial;
      for (final revision in _current.values) {
        _retire(revision);
      }
      _current.clear();
      await Future.wait([for (final revision in _draining) revision.drain!]);
    }();
  }
}

final class _RefreshOutcome implements Exception {
  const _RefreshOutcome(this.status, this.code);
  final String status;
  final String code;
}

String _failureCode(String prefix, Enum kind) =>
    '${prefix}_${kind.name}'.replaceAllMapped(
      RegExp('[A-Z]'),
      (match) => '_${match[0]!.toLowerCase()}',
    );

/// A batch may back several revisions/services. Only its last owner releases it;
/// a revision keeps its lease until its exact route, including admitted work, drains.
final class _CapturedConfiguration {
  _CapturedConfiguration(this.capture);

  final AdeleCredentialCapture capture;
  int _owners = 1; // Candidate preparation owns the initial lease.
  void retain() => _owners++;
  bool releaseOwner() => --_owners == 0;
}

final class _ConfiguredRevision {
  _ConfiguredRevision(
    this.configuration,
    this.scope,
    this.inference,
    this.catalog,
    this.route,
  );

  final OpenAiApiKeyConfiguration configuration;
  final _CapturedConfiguration? scope;
  final OpenAiConfiguredModelProvider inference;
  final OpenAiConfiguredModelCatalog catalog;
  final AdeleConfigurationContextRegistration route;
  AdelePublishedCapabilityGroup? publication;
  Future<void>? drain;

  List<AdeleCapabilityExposure> get exposures => [
    AdeleCapabilityExposure(
      providerId: configuration.providerId.value,
      capabilityId: modelProviderCapability.id.value,
      capabilityMajorVersion: modelProviderCapability.majorVersion,
      serviceId: modelProviderServiceId,
      displayName: configuration.displayName,
      configurationContext: route.configurationContext,
    ),
    AdeleCapabilityExposure(
      providerId: configuration.catalogProviderId.value,
      capabilityId: modelCatalogCapability.id.value,
      capabilityMajorVersion: modelCatalogCapability.majorVersion,
      serviceId: modelCatalogServiceId,
      displayName: configuration.displayName,
      configurationContext: route.configurationContext,
      association: AdeleProviderAssociation(
        capabilityId: modelProviderCapability.id.value,
        capabilityMajorVersion: modelProviderCapability.majorVersion,
        providerId: configuration.providerId.value,
      ),
    ),
  ];
}
