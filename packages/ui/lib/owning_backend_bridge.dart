import 'package:adele_contract/adele_contract.dart';

/// Calls only the exact sibling backend captured by this frontend presentation.
final class OwningBackendRequestChannel implements AdeleRequestChannel {
  const OwningBackendRequestChannel(this.serviceId);

  final String serviceId;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      requestOwningBackend(serviceId, method, payload);
}

Future<Object?> requestOwningBackend(
  String serviceId,
  String method,
  Map<String, Object?> payload,
) => throw UnsupportedError('Interpreted host only.');
