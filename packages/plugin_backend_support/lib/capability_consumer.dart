import 'package:adele_contract/adele_contract.dart';

part 'capability_consumer.g.dart';

/// Current provider metadata, without a backend route or host authority.
@AdeleValue('adele.capabilityConsumer.provider')
final class BackendCapabilityProvider {
  BackendCapabilityProvider({
    required this.capabilityId,
    required this.majorVersion,
    required this.providerId,
    required this.pluginId,
    required this.displayName,
    required this.serviceId,
  }) {
    if (capabilityId.isEmpty ||
        majorVersion < 1 ||
        providerId.isEmpty ||
        pluginId.isEmpty ||
        displayName.isEmpty) {
      throw const FormatException('Invalid capability provider metadata.');
    }
    adeleValidateServiceId(serviceId);
  }

  final String capabilityId;
  final int majorVersion;
  final String providerId;
  final String pluginId;
  final String displayName;
  final String serviceId;
}

/// One exact provider capture owned by the calling backend generation.
@AdeleValue('adele.capabilityConsumer.access')
final class BackendCapabilityAccess {
  BackendCapabilityAccess({required this.handle, required this.provider}) {
    if (handle.isEmpty) {
      throw const FormatException(
        'Capability access requires an opaque handle.',
      );
    }
  }

  final String handle;
  final BackendCapabilityProvider provider;
}

/// Host-mediated, context-free unary consumption through infrastructure access.
///
/// The host owns declaration checks, provider selection, exact-generation
/// liveness, handle limits and diagnostic sanitization. No operation accepts a
/// target backend, configuration context, or host invocation authority.
@AdeleService('adele.capabilityConsumer')
abstract interface class BackendCapabilityConsumerService {
  @AdeleMethod('discover')
  Future<List<BackendCapabilityProvider>> discover(
    String capabilityId,
    int majorVersion,
  );

  @AdeleMethod('resolve')
  Future<BackendCapabilityAccess?> resolve(
    String capabilityId,
    int majorVersion,
    String expectedServiceId,
    String? providerId,
  );

  /// Returns exactly `{ok: true, value: structuredValue}` or:
  /// ```text
  /// {ok: false, error: {declaredFailureType: String?, code: String,
  /// message: String, details: Map<String, Object?>}}
  /// ```
  ///
  /// All failure keys are required, including a null undeclared failure type.
  /// Wrapping preserves scalar, list, map and null semantic responses without
  /// adding a second semantic codec or confusing failures with returned maps.
  @AdeleMethod('invoke')
  Future<Map<String, Object?>> invoke(
    String handle,
    String method,
    Map<String, Object?> payload,
  );

  @AdeleMethod('release')
  Future<void> release(String handle);
}
