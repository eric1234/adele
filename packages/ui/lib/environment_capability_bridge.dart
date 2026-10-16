import 'dart:async';

import 'package:adele_contract/adele_contract.dart';

/// Resolves read access once among providers eligible for the captured Session
/// Environment, requiring the pane's separate Environment-read declaration.
/// [serviceId] is the consumer contract's expected generated service identity.
/// Null means denied, missing, incompatible, or exhausted access. Explicit
/// selection never falls back. The opaque result belongs only to this pane
/// presentation; it exposes neither a host token nor a backend route.
Future<String?> resolveEnvironmentCapabilityProvider(
  String capabilityId,
  int majorVersion,
  String serviceId,
  String? providerId,
) => throw UnsupportedError('Interpreted host only.');

/// Resolves buffered-process access for the captured Session Environment.
/// Requires the pane's separate buffered-process declaration and the selected
/// provider's explicit permission. Selection follows the same rules as read
/// access; an ineligible selected provider is rejected, never substituted.
/// The opaque handle uses [EnvironmentCapabilityRequestChannel] but grants only
/// buffered-process access per request, not reads or general process access.
Future<String?> resolveEnvironmentBufferedProcessCapabilityProvider(
  String capabilityId,
  int majorVersion,
  String serviceId,
  String? providerId,
) => throw UnsupportedError('Interpreted host only.');

/// Releases this presentation's handle and revokes its operation grants, without
/// cancelling independently owned backend work. Release handles when no longer
/// needed; the host bounds simultaneous handles.
bool releaseEnvironmentCapabilityProvider(String handle) =>
    throw UnsupportedError('Interpreted host only.');

/// A generated unary-client channel over one exact eligible provider selection.
/// Each request receives a fresh, operation-scoped grant of only the kind chosen
/// at resolution: Environment read or buffered-process access. It cannot select
/// another grant kind, Environment, backend, configuration context, or service.
/// Stale handles never follow replacements, and this channel supports no streams.
final class EnvironmentCapabilityRequestChannel implements AdeleRequestChannel {
  const EnvironmentCapabilityRequestChannel(this.handle);

  final String handle;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      requestEnvironmentCapability(handle, method, payload);
}

Future<Object?> requestEnvironmentCapability(
  String handle,
  String method,
  Map<String, Object?> payload,
) => throw UnsupportedError('Interpreted host only.');

/// Safe generated-client settlement: [true, interpretedValue] or [false, null].
/// Native exceptions/diagnostics are not reconstructed in the interpreted client.
/// Settlement does not extend the originating operation's grant or lifetime.
Future<List<dynamic>> settleEnvironmentCapabilityOperation(
  Future<dynamic> operation,
) => throw UnsupportedError('Interpreted host only.');
