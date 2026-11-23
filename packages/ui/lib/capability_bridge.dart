import 'dart:async';

import 'package:adele_contract/adele_contract.dart';

/// Current compatible provider metadata, in the Capability registry's order.
/// Entries contain providerId, pluginId, displayName and serviceId, not routes.
/// An empty list means no provider; null means denied or unavailable access.
List<Map<String, dynamic>>? discoverCapabilityProviders(
  String capabilityId,
  int majorVersion,
) => throw UnsupportedError('Interpreted host only.');

/// Observes registrations for the first Capability and generated service. Each
/// entry contains only `providerId` and `displayName` when [capture] is false;
/// this retains no handles and does not invoke a provider.
///
/// With capture, `status` is `ready`, `missing`, `ambiguous`, `stale` or `limit`.
/// Only `ready` includes a `handle`, for unary calls to the unique registration
/// of the second Capability/service explicitly associated with the observed one.
/// Neither observing nor capturing grants a channel to the observed provider.
/// IDs above 1,024 code units are not offered and overlong display names fall
/// back to their exact provider ID. Null means the exact declaration or
/// observation is unavailable (including more than 1,024 eligible providers).
List<Map<String, dynamic>>? observeAssociatedProviders(
  String capabilityId,
  int majorVersion,
  String serviceId,
  String associatedCapabilityId,
  int associatedMajorVersion,
  String associatedServiceId,
  bool capture,
) => throw UnsupportedError('Interpreted host only.');

/// Revalidate before accepting an earlier observation. Never resolves a new
/// registration, even when a replacement has the same provider ID.
bool isCapabilityProviderCurrent(String handle) =>
    throw UnsupportedError('Interpreted host only.');

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
/// For associated unary calls only, passing both expected failure identities
/// returns [false, failureCode] on an exact declared match. No backend-provided
/// message, details, or unknown code is returned.
Future<List<dynamic>> settleCapabilityOperation(
  Future<dynamic> operation, [
  String? declaredFailureType,
  String? failureCode,
]) => throw UnsupportedError('Interpreted host only.');
