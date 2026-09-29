import 'dart:async';

import 'package:adele_contract/adele_contract.dart';

/// Calls only the exact sibling backend captured by this frontend presentation.
final class OwningBackendRequestChannel implements AdeleStreamChannel {
  const OwningBackendRequestChannel(this.serviceId);

  final String serviceId;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      requestOwningBackend(serviceId, method, payload);

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) =>
      streamOwningBackend(serviceId, method, payload);
}

Future<Object?> requestOwningBackend(
  String serviceId,
  String method,
  Map<String, Object?> payload,
) => throw UnsupportedError('Interpreted host only.');

/// Safely awaits a generated backend query without transporting native errors.
/// Preserves the interpreted success value as [true, value], or [false, null].
/// This grants no authority; the originating channel enforces its own lifetime.
Future<List<dynamic>> settleOwningBackendOperation(Future<dynamic> operation) =>
    throw UnsupportedError('Interpreted host only.');

Stream<Object?> streamOwningBackend(
  String serviceId,
  String method,
  Map<String, Object?> payload,
) => throw UnsupportedError('Interpreted host only.');
