import 'dart:async';

import 'package:adele_contract/adele_contract.dart';

/// Current compatible provider metadata, in the Capability registry's order.
/// Entries contain providerId, pluginId, displayName and serviceId, not routes.
/// An empty list means no provider; null means denied or unavailable access.
List<Map<String, dynamic>>? discoverCapabilityProviders(
  String capabilityId,
  int majorVersion,
) => throw UnsupportedError('Interpreted host only.');

/// Resolves once using ordinary Capability selection, optionally explicitly.
/// [serviceId] is the consumer contract's expected generated service identity.
/// Null means denied, missing, incompatible, or exhausted access. No fallback is
/// attempted after selection. The opaque result belongs only to this presentation.
String? resolveCapabilityProvider(
  String capabilityId,
  int majorVersion,
  String serviceId,
  String? providerId,
) => throw UnsupportedError('Interpreted host only.');

/// Releases this presentation's handle and observations, not backend-owned work.
/// Release handles when no longer needed; the host bounds simultaneous handles.
bool releaseCapabilityProvider(String handle) =>
    throw UnsupportedError('Interpreted host only.');

/// An ordinary generated-client channel over one exact provider registration.
/// It cannot select a backend, configuration context, or another service. A stale
/// handle never follows a replacement; explicitly resolve again for new access.
final class CapabilityRequestChannel implements AdeleStreamChannel {
  const CapabilityRequestChannel(this.handle);

  final String handle;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      requestCapability(handle, method, payload);

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) =>
      streamCapability(handle, method, payload);
}

Future<Object?> requestCapability(
  String handle,
  String method,
  Map<String, Object?> payload,
) => throw UnsupportedError('Interpreted host only.');

Stream<Object?> streamCapability(
  String handle,
  String method,
  Map<String, Object?> payload,
) => throw UnsupportedError('Interpreted host only.');

/// Safe generated-client settlement: [true, interpretedValue] or [false, null].
/// Native exceptions/diagnostics are not reconstructed in the interpreted client.
Future<List<dynamic>> settleCapabilityOperation(Future<dynamic> operation) =>
    throw UnsupportedError('Interpreted host only.');
