import 'package:adele_contract/adele_contract.dart';

import 'adele_backend_records.dart';
import 'adele_plugin_backend_support.dart' show AdeleHostRequestMultiplexer;

/// The explicitly granted, generation-scoped configuration service.
const backendConfigurationServiceId = 'adele.configuration';

/// Bounded configuration outcomes without payloads or underlying errors.
enum AdeleConfigurationFailureKind {
  notAuthorized,
  configurationUnavailable,
  generationUnavailable,
  configurationAccessFailed,
}

final class AdeleConfigurationFailure implements Exception {
  const AdeleConfigurationFailure(this.kind);

  final AdeleConfigurationFailureKind kind;

  @override
  String toString() => 'Configuration access failed (${kind.name}).';
}

/// An immutable observation of the host-authorized nonsecret records.
final class AdeleRecordObservation {
  AdeleRecordObservation({
    required List<Map<String, Object?>> records,
    required bool isComplete,
  }) : this._(adeleCopyBackendRecords(records), isComplete);

  AdeleRecordObservation._(this.records, this.isComplete);

  /// Deeply copied records using the bounded [AdeleBackendRecords] grammar.
  final List<Map<String, Object>> records;

  /// False when invalid records were omitted, including an all-invalid result.
  final bool isComplete;
}

/// Read-only observations through one captured infrastructure grant.
///
/// The host owns installation scope and generation authority. Observations do
/// not mutate startup records, grant credential access or refresh live providers.
final class AdeleConfigurationClient {
  AdeleConfigurationClient({
    required AdeleHostRequestMultiplexer hostRequests,
    required String hostInfrastructureContext,
  }) : _channel = hostRequests.bindInfrastructure(
         hostInfrastructureContext: hostInfrastructureContext,
         serviceId: backendConfigurationServiceId,
       );

  final AdeleRequestChannel _channel;

  /// Reads current records without caller-selected identities or scope.
  /// No failure retains a response payload or underlying exception.
  Future<AdeleRecordObservation> currentRecords() async {
    Object? response;
    try {
      // A fresh plain map crosses AOT isolate groups; unmodifiable wrappers do not.
      response = await _channel.request('currentRecords', <String, Object?>{});
    } on AdeleRemoteFailure catch (failure) {
      throw AdeleConfigurationFailure(switch (failure.code) {
        'host_infrastructure_unavailable' || 'host_invocation_unavailable' =>
          AdeleConfigurationFailureKind.generationUnavailable,
        'service_unavailable' => AdeleConfigurationFailureKind.notAuthorized,
        _ => AdeleConfigurationFailureKind.configurationAccessFailed,
      });
    } on Object {
      throw const AdeleConfigurationFailure(
        AdeleConfigurationFailureKind.configurationAccessFailed,
      );
    }

    if (response is Map<String, Object?>) {
      if (response.length == 1) {
        final failure = response['failure'];
        for (final kind in AdeleConfigurationFailureKind.values) {
          if (failure == kind.name) throw AdeleConfigurationFailure(kind);
        }
      }
      final isComplete = response['isComplete'];
      if (response.length == 2 && isComplete is bool) {
        try {
          return AdeleRecordObservation._(
            adeleCopyBackendRecords(response['records']),
            isComplete,
          );
        } on Object {
          throw const AdeleConfigurationFailure(
            AdeleConfigurationFailureKind.configurationAccessFailed,
          );
        }
      }
    }
    throw const AdeleConfigurationFailure(
      AdeleConfigurationFailureKind.configurationAccessFailed,
    );
  }
}
