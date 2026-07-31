/// Experimental declarations and transport-neutral runtime types for typed
/// ADELE plugin contracts.
library;

final class AdeleContract {
  const AdeleContract(this.name);

  final String name;
}

final class AdeleValue {
  const AdeleValue();
}

final class AdeleMethod {
  const AdeleMethod(this.name);

  final String name;
}

final class AdeleField {
  const AdeleField(this.name);

  final String name;
}

abstract interface class AdeleRequestChannel {
  Future<Object?> request(String method, Map<String, Object?> payload);
}

class AdeleRemoteFailure implements Exception {
  const AdeleRemoteFailure({
    required this.code,
    required this.message,
    this.details = const <String, Object?>{},
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'AdeleRemoteFailure($code): $message';
}

final class AdeleProtocolException implements FormatException {
  const AdeleProtocolException(this.message, [this.source, this.offset]);

  @override
  final String message;

  @override
  final Object? source;

  @override
  final int? offset;

  @override
  String toString() => 'AdeleProtocolException: $message';
}
